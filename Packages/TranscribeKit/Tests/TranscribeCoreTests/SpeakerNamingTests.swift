import Foundation
import Testing
@testable import TranscribeCore

struct SpeakerNamingTests {
    /// A Meet tile: the name's text seven levels below the tile, the talking
    /// class (when talking) somewhere inside it.
    func meetTile(_ name: String, talking: Bool) -> AXNode {
        var node = AXNode(role: "AXStaticText", value: name)
        for level in 0..<CallParser.meetTileDepth {
            node = AXNode(role: "AXGroup", classes: talking && level == 2 ? ["v5h6Xc"] : ["xyz"], children: [node])
        }
        return node
    }

    func meetWindow(_ tiles: [(String, Bool)]) -> [AXWindow] {
        [AXWindow(title: "Meet - Weekly sync", tree: AXNode(role: "AXWebArea", children: tiles.map { meetTile($0.0, talking: $0.1) }))]
    }

    @Test func readsMeetTilesAndTheTalker() {
        let r = CallParser.read(.googleMeet, windows: meetWindow([("Ann Lee", true), ("Bo Park", false), ("You", false)]))
        #expect(r.participants == ["Ann Lee", "Bo Park", "You"])
        #expect(r.speaking == ["Ann Lee"])
        #expect(r.me == "You")
    }

    @Test func ignoresWindowsThatAreNotMeet() {
        let w = [AXWindow(title: "Inbox - Gmail", tree: meetTile("Ann Lee", talking: true))]
        #expect(CallParser.read(.googleMeet, windows: w).windowFound == false)
    }

    @Test func readsLabelledTeamsAndSlackTiles() {
        let tree = AXNode(role: "AXGroup", children: [
            AXNode(role: "AXGroup", label: "Ann Lee, muted"),
            AXNode(role: "AXGroup", label: "Bo Park, speaking"),
            AXNode(role: "AXStaticText", value: "Mark (You)"),
            AXNode(role: "AXGroup", classes: ["c-huddle_avatar--speaking"], children: [AXNode(role: "AXStaticText", value: "Cy Diaz")]),
        ])
        let r = CallParser.read(.slack, windows: [AXWindow(title: "Huddle", tree: tree)])
        #expect(r.participants == ["Ann Lee", "Mark"])
        #expect(Set(r.speaking) == ["Bo Park", "Cy Diaz"])
        #expect(r.me == "Mark")
    }

    func sample(_ t: Double, speaking: [String], participants: [String] = ["A", "B", "Me"]) -> CallSample {
        CallSample(time: t, reading: CallReading(speaking: speaking, participants: participants, me: "Me", windowFound: true))
    }

    @Test func namesALineByWhoWasTalkingForMostOfIt() {
        let samples = [sample(0, speaking: ["A"]), sample(1, speaking: ["A"]), sample(2, speaking: ["B"])]
        #expect(SpeakerAttribution.name(start: 0, end: 2.5, samples: samples, myNames: []) == "A")
        #expect(SpeakerAttribution.name(start: 1.5, end: 3, samples: samples, myNames: []) == "B")
    }

    @Test func neverNamesYouOrAnUnclearMoment() {
        let samples = [sample(0, speaking: ["Me"]), sample(1, speaking: ["A", "B"])]
        #expect(SpeakerAttribution.name(start: 0, end: 2, samples: samples, myNames: []) == nil)
        // A stuck app: a reading stands for at most `hold` seconds.
        #expect(SpeakerAttribution.name(start: 10, end: 12, samples: [sample(0, speaking: ["A"])], myNames: []) == nil)
    }

    @Test func aCallOfTwoNamesTheOtherPersonWhateverIsMarked() {
        let samples = [sample(0, speaking: [], participants: ["A", "Mark"])]
        #expect(SpeakerAttribution.name(start: 0, end: 1, samples: samples, myNames: ["Mark"]) == "A")
    }

    @Test func transcriptSplitsAndLabelsByCallReadings() {
        let words = ["one", "two", "three", "four"].enumerated().map { i, w in
            TranscribedWord(text: w, start: Double(i) * 0.5, end: Double(i) * 0.5 + 0.4, source: .system)
        }
        let samples = [sample(0, speaking: ["A"]), sample(1, speaking: ["B"])]
        let segments = TranscriptBuilder.segments(from: words, callSamples: samples)
        #expect(segments.map(\.speaker) == ["A", "B"])
        #expect(segments.map(\.text) == ["one two", "three four"])
    }

    @Test func healthNoticesNobodyEverMarked() {
        let quiet = (0..<40).map { sample(Double($0) * 0.5, speaking: []) }
        #expect(SpeakerNamingHealth.problem(samples: quiet, systemWords: 100) != nil)
        #expect(SpeakerNamingHealth.problem(samples: quiet, systemWords: 5) == nil)
        let fine = (0..<40).map { sample(Double($0) * 0.5, speaking: ["A"]) }
        #expect(SpeakerNamingHealth.problem(samples: fine, systemWords: 100) == nil)
        let empty = (0..<40).map { _ in CallSample(time: 0, reading: CallReading(windowFound: true)) }
        #expect(SpeakerNamingHealth.problem(samples: empty, systemWords: 100) != nil)
    }

    @Test func dumpsHideNamesButKeepTheShape() {
        #expect(AXDump.mask("Ann Lee, muted") == "🔳🔳🔳 🔳🔳🔳, muted")
        #expect(AXDump.mask("Room 42 (You)") == "🔳🔳🔳🔳 🔲🔲 (You)")
        let report = SpeakerNamingReport(platform: .googleMeet, app: "Google Chrome 142", transcribeVersion: "1.0.0",
                                         macOSVersion: "15.1", problem: "x", windows: meetWindow([("Ann Lee", true)]))
        let body = report.body()
        #expect(!body.contains("Ann"))
        #expect(body.contains("v5h6Xc"))
        #expect(report.newIssueURL.absoluteString.count < 8000)
        let big = meetWindow((0..<300).map { ("Person \($0) \"quoted\"", false) })
        let large = SpeakerNamingReport(platform: .googleMeet, app: "Chrome", transcribeVersion: "1", macOSVersion: "15",
                                        problem: "x", windows: big)
        #expect(large.newIssueURL.absoluteString.count < 8000)
    }
}
