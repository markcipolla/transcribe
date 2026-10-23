import AppKit
import Foundation

/// Notices Google Meet, Microsoft Teams and Slack huddle calls.
///
/// A call is an app from ``MeetingClassifier`` holding the microphone open.
/// For a browser that alone is not enough, since a browser uses the microphone
/// for plenty besides meetings, so its tabs are checked for a Meet, Teams or
/// Slack page. Tab reads go through AppleScript and are cached briefly, because
/// detection polls every couple of seconds.
public actor MeetingDetector {
    private struct CachedTabs {
        let tabs: [BrowserTab]?
        let readAt: Date
    }

    private var tabCache: [String: CachedTabs] = [:]
    private let tabCacheLifetime: TimeInterval

    public init(tabCacheLifetime: TimeInterval = 15) {
        self.tabCacheLifetime = tabCacheLifetime
    }

    /// The meeting in progress, if there is one.
    public func detect() async -> DetectedMeeting? {
        let apps = Self.microphoneApps()
        var unverifiedBrowser: DetectedMeeting?
        var siteApp: DetectedMeeting?
        var meetingApp: DetectedMeeting?

        for app in apps {
            switch MeetingClassifier.kind(ofApp: app.bundleID) {
            case .meetingApp(let platform):
                meetingApp = meetingApp ?? DetectedMeeting(
                    platform: platform, appBundleID: app.bundleID, appPID: app.pid,
                    appName: Self.name(of: app.bundleID), title: nil)
            case .browser(let scripting):
                let tabs = await tabs(of: app.bundleID, scripting: scripting)
                if let tabs, let match = MeetingClassifier.meeting(in: tabs) {
                    return DetectedMeeting(platform: match.platform, appBundleID: app.bundleID,
                                           appPID: app.pid, appName: Self.name(of: app.bundleID),
                                           title: match.title, meetingCode: match.code)
                }
                // A meeting PWA's window is in neither list: the browser's tab
                // scripting leaves it out, and the PWA's own bundle has no
                // scripting. The app running is the evidence.
                if let site = Self.runningMeetingSiteApp() {
                    siteApp = siteApp ?? DetectedMeeting(
                        platform: site.platform, appBundleID: app.bundleID, appPID: app.pid,
                        appName: site.name, title: nil)
                } else if tabs == nil {
                    unverifiedBrowser = unverifiedBrowser ?? DetectedMeeting(
                        platform: .browserCall, appBundleID: app.bundleID, appPID: app.pid,
                        appName: Self.name(of: app.bundleID), title: nil)
                }
            case nil:
                continue
            }
        }
        return meetingApp ?? siteApp ?? unverifiedBrowser
    }

    /// Whether the process that revealed `meeting` still has the microphone
    /// open. Cheap enough to call on every poll, unlike ``detect()``.
    ///
    /// Keyed on the process, not the bundle: a second copy of the same browser
    /// holding the microphone — a WebDriver's, say — must not keep a finished
    /// recording running. Meetings made without a process fall back to the
    /// bundle.
    public nonisolated func isStillActive(_ meeting: DetectedMeeting) -> Bool {
        Self.microphoneApps().contains {
            meeting.appPID == 0 ? $0.bundleID == meeting.appBundleID : $0.pid == meeting.appPID
        }
    }

    /// Forget cached tab lists, so the next detection reads them fresh.
    public func invalidateTabs() {
        tabCache.removeAll()
    }

    private func tabs(of app: String, scripting: BrowserScripting) async -> [BrowserTab]? {
        if let cached = tabCache[app], Date().timeIntervalSince(cached.readAt) < tabCacheLifetime {
            return cached.tabs
        }
        // An Apple event is addressed to a bundle, not a process, so with two
        // copies of a browser running it can be answered by the wrong one — a
        // WebDriver's, whose tabs say nothing about the call. A browser on a
        // call always has a page open, so a reply holding none is no answer.
        let tabs = await BrowserTabReader.tabs(bundleID: app, scripting: scripting)
            .flatMap { $0.contains { $0.url.hasPrefix("http") } ? $0 : nil }
        tabCache[app] = CachedTabs(tabs: tabs, readAt: Date())
        return tabs
    }

    /// The running apps whose processes have the microphone open, each with the
    /// process that holds it: helpers attributed to the app that contains them.
    struct MicrophoneApp: Hashable {
        let bundleID: String
        let pid: pid_t
    }

    static func microphoneApps() -> Set<MicrophoneApp> {
        var apps = Set<MicrophoneApp>()
        for process in AudioProcessList.usingMicrophone() {
            var app = process.appBundleID
            var pid = process.appPID
            if app.hasPrefix(MeetingClassifier.webKitProcessPrefix) {
                // WebKit's GPU process captures for every WebKit client; Safari is the
                // one that can be on a meeting page.
                guard let safari = runningApp(withPrefix: "com.apple.Safari") else { continue }
                app = safari.bundleID
                pid = safari.pid
            }
            // Only script apps that are really running: `tell application id` on
            // one that is not would launch it.
            guard let running = runningApp(containing: app) else { continue }
            apps.insert(MicrophoneApp(bundleID: running, pid: pid))
        }
        return apps
    }

    /// A running single-site browser app for a meeting service, such as the
    /// Google Meet PWA installed from Chrome.
    ///
    // ponytail: an idle Meet PWA plus unrelated browser microphone use reads as
    // a call. Narrow it by reading the PWA's window title if that ever bites.
    static func runningMeetingSiteApp() -> (platform: MeetingPlatform, name: String)? {
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, MeetingClassifier.isSiteApp(id),
                  let name = app.localizedName,
                  let platform = MeetingClassifier.siteAppPlatform(named: name)
            else { continue }
            return (platform, name)
        }
        return nil
    }

    /// `bundleID` if it is a running app, else the nearest running app whose ID
    /// it extends, so `com.google.Chrome.helper` resolves to `com.google.Chrome`
    /// when the helper's location could not be read.
    private static func runningApp(containing bundleID: String) -> String? {
        var components = bundleID.split(separator: ".")
        while components.count >= 2 {
            let candidate = components.joined(separator: ".")
            if isRunning(candidate) { return candidate }
            components.removeLast()
        }
        return nil
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func runningApp(withPrefix prefix: String) -> MicrophoneApp? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier?.hasPrefix(prefix) == true }
            .map { MicrophoneApp(bundleID: $0.bundleIdentifier!, pid: $0.processIdentifier) }
    }

    static func name(of bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? bundleID
    }
}
