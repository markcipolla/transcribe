import Foundation
import Testing
@testable import TranscribeCore

struct TitlePassageTests {
    func segment(_ text: String, _ source: AudioSource = .system) -> TranscriptSegment {
        TranscriptSegment(source: source, start: 0, end: 0, text: text)
    }

    /// Numbered words, so a test can see which part of the meeting was taken.
    func numbered(_ range: Range<Int>) -> TranscriptSegment {
        segment(range.map { "w\($0)" }.joined(separator: " "))
    }

    @Test func aShortMeetingIsPassedWholeWithoutSpeakerLabels() {
        let text = TitlePassage.text(from: [
            segment("Shall we start with the release?"),
            segment("Sure. We're down to four open bugs.", .microphone),
        ])
        #expect(text == "Shall we start with the release?\nSure. We're down to four open bugs.")
    }

    @Test func aLongMeetingIsCutToEvenlySpacedStretches() {
        let segments = stride(from: 0, to: 10_000, by: 100).map { numbered($0..<$0 + 100) }
        let text = TitlePassage.text(from: segments, wordBudget: 400, stretches: 4)
        let stretches = text.components(separatedBy: "\n\n")
        #expect(stretches.count == 4)
        #expect(text.split(whereSeparator: \.isWhitespace).count == 400)
        // Each stretch is the middle of its quarter: 1,250, 3,750, 6,250, 8,750.
        #expect(stretches[0].hasPrefix("w1200 "))
        #expect(stretches[3].hasSuffix(" w8799"))
        // The greetings and goodbyes are left out.
        #expect(!text.contains("w0 "))
        #expect(!text.contains("w9999"))
    }

    @Test func stretchesKeepTheBreaksBetweenTurns() {
        let segments = [numbered(0..<50), numbered(50..<100)]
        let text = TitlePassage.text(from: segments, wordBudget: 20, stretches: 1)
        #expect(text == (40..<50).map { "w\($0)" }.joined(separator: " ")
            + "\n" + (50..<60).map { "w\($0)" }.joined(separator: " "))
    }

    @Test func aStretchNeverRunsPastTheEnd() {
        let text = TitlePassage.text(from: [numbered(0..<11)], wordBudget: 10, stretches: 1)
        #expect(text.split(separator: " ").count == 10)
    }

    @Test func nothingSaidIsAnEmptyPassage() {
        #expect(TitlePassage.text(from: []).isEmpty)
        #expect(TitlePassage.text(from: [segment("")]).isEmpty)
    }
}

struct MeetingSummaryTests {
    @Test func acceptsATitleAndDescription() throws {
        let summary = try #require(MeetingSummary(
            title: "Billing migration cut-over plan",
            description: "The team agrees to move billing on the 23rd."))
        #expect(summary.title == "Billing migration cut-over plan")
        #expect(summary.description == "The team agrees to move billing on the 23rd.")
    }

    @Test func tidiesPunctuationQuotesAndSpacing() throws {
        let summary = try #require(MeetingSummary(
            title: "  \"Quarterly   planning review.\" ",
            description: " Covers the\nroadmap. "))
        #expect(summary.title == "Quarterly planning review")
        #expect(summary.description == "Covers the roadmap.")
    }

    /// What the model wrote when handed a 15,000-word transcript whole.
    @Test func rejectsTheModelBreakingDown() {
        #expect(MeetingSummary(title: "TRANSCRIPT", description: "") == nil)
        #expect(MeetingSummary(
            title: "Answers presented by the House of Commons Speaker (Mr. Chair) and members of the House of Commons.",
            description: "") == nil)
        #expect(MeetingSummary(title: "Weekly sync", description: "") == nil)
        #expect(MeetingSummary(
            title: "One two three four five six seven eight nine ten eleven twelve thirteen",
            description: "Too long to be a title.") == nil)
    }
}

struct TranscriptSummaryMetadataTests {
    let summary = MeetingSummary(title: "Billing migration plan",
                                 description: "The team plans the cut-over.")!

    @Test func namesAMeetingThatHadNoName() {
        var metadata = TranscriptMetadata(title: nil, platform: .teams, startedAt: Date())
        metadata.apply(summary)
        #expect(metadata.title == "Billing migration plan")
        #expect(metadata.description == "The team plans the cut-over.")
    }

    @Test func keepsTheNameAMeetingAlreadyHad() {
        var metadata = TranscriptMetadata(title: "Weekly sync", platform: .googleMeet, startedAt: Date())
        metadata.apply(summary)
        #expect(metadata.title == "Weekly sync")
        #expect(metadata.description == "The team plans the cut-over.")
    }

    @Test func rendersTheDescription() {
        var metadata = TranscriptMetadata(title: "Weekly sync", platform: .googleMeet, startedAt: Date())
        metadata.description = "The team plans the \"cut-over\"."
        let markdown = TranscriptRenderer.markdown(metadata: metadata, segments: [], duration: 60, inProgress: false)
        #expect(markdown.contains("title: \"Weekly sync\"\ndescription: \"The team plans the \\\"cut-over\\\".\"\n"))
        #expect(markdown.contains("# Weekly sync\n\nThe team plans the \"cut-over\".\n\n- **Date:**"))
    }

    @Test func leavesOutAMissingDescription() {
        let metadata = TranscriptMetadata(title: "Weekly sync", platform: .googleMeet, startedAt: Date())
        let markdown = TranscriptRenderer.markdown(metadata: metadata, segments: [], duration: 60, inProgress: false)
        #expect(!markdown.contains("description:"))
        #expect(markdown.contains("# Weekly sync\n\n- **Date:**"))
    }
}
