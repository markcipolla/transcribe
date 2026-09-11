import Foundation

public enum MeetingPlatform: String, Sendable, Codable {
    case googleMeet = "Google Meet"
    case teams = "Microsoft Teams"
    case slack = "Slack"
    /// A browser is on a call but its tabs cannot be read (no AppleScript
    /// support, or Automation permission was declined), so which service it
    /// is on is unknown.
    case browserCall = "Browser Call"
    /// Started by hand rather than detected.
    case manual = "Recording"
}

/// A meeting that is happening now, as far as can be told from outside it.
public struct DetectedMeeting: Sendable, Equatable {
    public let platform: MeetingPlatform
    /// The app whose microphone use revealed the meeting. Detection watches it
    /// to tell when the meeting is over.
    public let appBundleID: String
    public let appName: String
    /// The meeting's name, when the app exposes one.
    public let title: String?
    /// What tells this call apart from the next one in the same app: the Meet
    /// code (`abc-defg-hij`). Nil where the app does not expose one.
    public let meetingCode: String?

    public init(platform: MeetingPlatform, appBundleID: String, appName: String,
                title: String?, meetingCode: String? = nil) {
        self.platform = platform
        self.appBundleID = appBundleID
        self.appName = appName
        self.title = title
        self.meetingCode = meetingCode
    }

    /// Whether `other` is the same call, as opposed to a later one in the
    /// same app. Used to stop a declined call from blocking the next.
    public func isSameMeeting(as other: DetectedMeeting) -> Bool {
        appBundleID == other.appBundleID && platform == other.platform && meetingCode == other.meetingCode
    }
}

public struct BrowserTab: Sendable, Equatable {
    public let url: String
    public let title: String

    public init(url: String, title: String) {
        self.url = url
        self.title = title
    }
}

/// How a browser's tabs can be listed over AppleScript.
public enum BrowserScripting: Sendable, Equatable {
    /// Chrome's dictionary: `URL` and `title` of `tabs of window`.
    case chromium
    /// Safari's dictionary: `URL` and `name` of `tabs of window`.
    case safari
    /// No usable tab scripting.
    case none
}

public enum AppKind: Sendable, Equatable {
    /// An app that only holds the microphone open for a call, so that alone
    /// reveals one.
    case meetingApp(MeetingPlatform)
    case browser(BrowserScripting)
}

/// The rules for recognising meeting apps and meeting tabs. Pure, so they
/// can be tested without a meeting.
public enum MeetingClassifier {
    static let meetingApps: [(prefix: String, platform: MeetingPlatform)] = [
        ("com.microsoft.teams", .teams),
        ("com.tinyspeck.slackmacgap", .slack),
    ]

    static let browsers: [(prefix: String, scripting: BrowserScripting)] = [
        ("com.google.Chrome", .chromium),
        ("com.microsoft.edgemac", .chromium),
        ("com.brave.Browser", .chromium),
        ("company.thebrowser.Browser", .chromium),  // Arc
        ("com.vivaldi.Vivaldi", .chromium),
        ("org.chromium.Chromium", .chromium),
        ("com.apple.Safari", .safari),
        ("com.apple.SafariTechnologyPreview", .safari),
        ("company.thebrowser.dia", .none),
        ("com.operasoftware.Opera", .none),
        ("org.mozilla.firefox", .none),
        ("app.zen-browser.zen", .none),
    ]

    /// Safari captures the microphone in WebKit's shared GPU process, which
    /// lives outside any app bundle.
    public static let webKitProcessPrefix = "com.apple.WebKit."

    public static func kind(ofApp bundleID: String) -> AppKind? {
        if let app = meetingApps.first(where: { bundleID.hasPrefix($0.prefix) }) {
            return .meetingApp(app.platform)
        }
        if let browser = browsers.first(where: { bundleID.hasPrefix($0.prefix) }) {
            return .browser(browser.scripting)
        }
        return nil
    }

    /// The meeting open in a set of browser tabs, if any. Meet wins over Teams
    /// and Slack when both are open, since a Meet tab is only ever a meeting
    /// while a Teams or Slack tab is often just chat.
    public static func meeting(in tabs: [BrowserTab])
        -> (platform: MeetingPlatform, title: String?, code: String?)? {
        if let meet = tabs.first(where: { isMeetCall($0.url) }) {
            return (.googleMeet, meetTitle(from: meet.title), meetCode(in: meet.url))
        }
        if tabs.contains(where: { isTeamsWeb($0.url) }) {
            return (.teams, nil, nil)
        }
        if tabs.contains(where: { isSlackWeb($0.url) }) {
            return (.slack, nil, nil)
        }
        return nil
    }

    // Computed because `Regex` is not Sendable and so cannot be a stored static.
    private static var meetCallPattern: Regex<Substring> { #/^https?://meet\.google\.com/[a-z]{3,}-[a-z]{4,}-[a-z]{3,}/# }
    private static var meetCodePattern: Regex<Substring> { #/[a-z]{3,}-[a-z]{4,}-[a-z]{3,}/# }

    static func isMeetCall(_ url: String) -> Bool {
        url.lowercased().prefixMatch(of: meetCallPattern) != nil
    }

    static func meetCode(in url: String) -> String? {
        guard isMeetCall(url) else { return nil }
        return url.lowercased().firstMatch(of: meetCodePattern).map { String($0.output) }
    }

    static func isTeamsWeb(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host()?.lowercased() else { return false }
        return ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"].contains(host)
    }

    /// Slack in a browser, where a huddle runs inside the workspace page.
    static func isSlackWeb(_ url: String) -> Bool {
        URL(string: url)?.host()?.lowercased() == "app.slack.com"
    }

    /// The meeting name from a Meet tab title such as "Meet – Weekly sync".
    /// Nil when the title is only the meeting code, which names nothing.
    static func meetTitle(from tabTitle: String) -> String? {
        var title = tabTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Meet - ", "Meet – ", "Meet — ", "Meet: "] where title.hasPrefix(prefix) {
            title.removeFirst(prefix.count)
            break
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title == "Meet" || title == "Google Meet" { return nil }
        if title.lowercased().wholeMatch(of: meetCodePattern) != nil { return nil }
        return title
    }
}
