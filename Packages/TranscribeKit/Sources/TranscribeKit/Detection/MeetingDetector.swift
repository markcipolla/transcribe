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
        var meetingApp: DetectedMeeting?

        for app in apps {
            switch MeetingClassifier.kind(ofApp: app) {
            case .meetingApp(let platform):
                meetingApp = meetingApp ?? DetectedMeeting(
                    platform: platform, appBundleID: app, appName: Self.name(of: app), title: nil)
            case .browser(let scripting):
                guard let tabs = await tabs(of: app, scripting: scripting) else {
                    unverifiedBrowser = unverifiedBrowser ?? DetectedMeeting(
                        platform: .browserCall, appBundleID: app, appName: Self.name(of: app), title: nil)
                    continue
                }
                if let match = MeetingClassifier.meeting(in: tabs) {
                    return DetectedMeeting(platform: match.platform, appBundleID: app,
                                           appName: Self.name(of: app), title: match.title,
                                           meetingCode: match.code)
                }
            case nil:
                continue
            }
        }
        return meetingApp ?? unverifiedBrowser
    }

    /// Whether the app that revealed `meeting` still has the microphone open.
    /// Cheap enough to call on every poll, unlike ``detect()``.
    public nonisolated func isStillActive(_ meeting: DetectedMeeting) -> Bool {
        Self.microphoneApps().contains(meeting.appBundleID)
    }

    /// Forget cached tab lists, so the next detection reads them fresh.
    public func invalidateTabs() {
        tabCache.removeAll()
    }

    private func tabs(of app: String, scripting: BrowserScripting) async -> [BrowserTab]? {
        if let cached = tabCache[app], Date().timeIntervalSince(cached.readAt) < tabCacheLifetime {
            return cached.tabs
        }
        let tabs = await BrowserTabReader.tabs(bundleID: app, scripting: scripting)
        tabCache[app] = CachedTabs(tabs: tabs, readAt: Date())
        return tabs
    }

    /// Bundle IDs of the running apps whose processes have the microphone open,
    /// with helper processes attributed to the app that contains them.
    static func microphoneApps() -> Set<String> {
        var apps = Set<String>()
        for process in AudioProcessList.usingMicrophone() {
            var app = process.appBundleID
            if app.hasPrefix(MeetingClassifier.webKitProcessPrefix) {
                // WebKit's GPU process captures for every WebKit client; Safari is the
                // one that can be on a meeting page.
                guard let safari = runningApp(withPrefix: "com.apple.Safari") else { continue }
                app = safari
            }
            // Only script apps that are really running: `tell application id` on
            // one that is not would launch it.
            guard let running = runningApp(containing: app) else { continue }
            apps.insert(running)
        }
        return apps
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

    private static func runningApp(withPrefix prefix: String) -> String? {
        NSWorkspace.shared.runningApplications
            .compactMap(\.bundleIdentifier)
            .first { $0.hasPrefix(prefix) }
    }

    static func name(of bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? bundleID
    }
}
