import Testing
@testable import TranscribeCore

struct MeetingClassifierTests {
    @Test(arguments: [
        ("com.microsoft.teams2", AppKind.meetingApp(.teams)),
        ("com.microsoft.teams", AppKind.meetingApp(.teams)),
        ("com.tinyspeck.slackmacgap", AppKind.meetingApp(.slack)),
        ("com.google.Chrome", AppKind.browser(.chromium)),
        ("com.google.Chrome.canary", AppKind.browser(.chromium)),
        ("company.thebrowser.Browser", AppKind.browser(.chromium)),
        ("com.apple.Safari", AppKind.browser(.safari)),
        ("org.mozilla.firefox", AppKind.browser(.none)),
    ])
    func recognisesMeetingApps(bundleID: String, kind: AppKind) {
        #expect(MeetingClassifier.kind(ofApp: bundleID) == kind)
    }

    @Test func ignoresOtherApps() {
        #expect(MeetingClassifier.kind(ofApp: "com.apple.VoiceMemos") == nil)
        #expect(MeetingClassifier.kind(ofApp: "com.microsoft.edgemac.helper") == .browser(.chromium))
    }

    @Test func findsAMeetCallAmongTabs() {
        let tabs = [
            BrowserTab(url: "https://mail.google.com/mail/u/0/", title: "Inbox"),
            BrowserTab(url: "https://meet.google.com/abc-defg-hij?authuser=0", title: "Meet – Weekly sync"),
        ]
        let match = MeetingClassifier.meeting(in: tabs)
        #expect(match?.platform == .googleMeet)
        #expect(match?.title == "Weekly sync")
        #expect(match?.code == "abc-defg-hij")
    }

    @Test func tellsConsecutiveMeetCallsApart() {
        let first = DetectedMeeting(platform: .googleMeet, appBundleID: "com.google.Chrome",
                                    appName: "Chrome", title: nil, meetingCode: "abc-defg-hij")
        let same = DetectedMeeting(platform: .googleMeet, appBundleID: "com.google.Chrome",
                                   appName: "Chrome", title: "Renamed", meetingCode: "abc-defg-hij")
        let next = DetectedMeeting(platform: .googleMeet, appBundleID: "com.google.Chrome",
                                   appName: "Chrome", title: nil, meetingCode: "xyz-wxyz-xyz")
        #expect(first.isSameMeeting(as: same))
        #expect(!first.isSameMeeting(as: next))
    }

    @Test func meetLandingPageIsNotACall() {
        let tabs = [BrowserTab(url: "https://meet.google.com/landing", title: "Google Meet")]
        #expect(MeetingClassifier.meeting(in: tabs) == nil)
    }

    @Test func meetingCodeIsNotATitle() {
        #expect(MeetingClassifier.meetTitle(from: "Meet - abc-defg-hij") == nil)
        #expect(MeetingClassifier.meetTitle(from: "Meet") == nil)
        #expect(MeetingClassifier.meetTitle(from: "Meet – Design review") == "Design review")
    }

    @Test func findsTeamsOnTheWeb() {
        for url in ["https://teams.microsoft.com/v2/", "https://teams.live.com/meet/123",
                    "https://teams.cloud.microsoft/"] {
            #expect(MeetingClassifier.meeting(in: [BrowserTab(url: url, title: "Teams")])?.platform == .teams)
        }
        #expect(MeetingClassifier.meeting(in: [BrowserTab(url: "https://example.com/teams.microsoft.com",
                                                          title: "")]) == nil)
    }

    @Test func findsSlackOnTheWeb() {
        let slack = BrowserTab(url: "https://app.slack.com/client/T0123/C0456", title: "general - Acme - Slack")
        #expect(MeetingClassifier.meeting(in: [slack])?.platform == .slack)
        #expect(MeetingClassifier.meeting(in: [BrowserTab(url: "https://slack.com/help", title: "")]) == nil)
        let meet = BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet – Standup")
        #expect(MeetingClassifier.meeting(in: [slack, meet])?.platform == .googleMeet)
    }
}

struct AppBundlePathTests {
    @Test func attributesHelpersToTheirApp() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/"
            + "Versions/140.0/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        #expect(AppBundlePath.outermostApp(in: helper) == "/Applications/Google Chrome.app")
        #expect(AppBundlePath.outermostApp(in: "/Applications/Safari.app") == "/Applications/Safari.app")
        #expect(AppBundlePath.outermostApp(in: "/usr/libexec/coreaudiod") == nil)
    }
}

struct BrowserTabReaderTests {
    @Test func parsesOsascriptOutput() {
        let output = "https://a.example/\u{1F}A\u{1E}https://meet.google.com/abc-defg-hij\u{1F}Meet – X\u{1E}\n"
        #expect(BrowserTabList.parse(output) == [
            BrowserTab(url: "https://a.example/", title: "A"),
            BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet – X"),
        ])
    }
}

extension MeetingPlatform: CustomTestStringConvertible {
    public var testDescription: String { rawValue }
}
