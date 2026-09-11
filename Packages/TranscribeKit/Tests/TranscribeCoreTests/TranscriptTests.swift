import Foundation
import Testing
@testable import TranscribeCore

struct TranscriptBuilderTests {
    func words(_ text: String, from start: Double, source: AudioSource, spacing: Double = 0.4) -> [TranscribedWord] {
        text.split(separator: " ").enumerated().map { index, word in
            let time = start + Double(index) * spacing
            return TranscribedWord(text: String(word), start: time, end: time + 0.3, source: source)
        }
    }

    @Test func interleavesSpeakersInTimeOrder() {
        let all = words("Hi everyone, thanks for joining.", from: 0, source: .system)
            + words("Hey, good to see you.", from: 5, source: .microphone)
            + words("Let's get started.", from: 9, source: .system)
        let segments = TranscriptBuilder.segments(from: all)
        #expect(segments.map(\.source) == [.system, .microphone, .system])
        #expect(segments[1].text == "Hey, good to see you.")
        #expect(segments[1].start == 5)
    }

    @Test func mergesAPausingSpeakerIntoOneTurn() {
        let all = words("First thought.", from: 0, source: .system)
            + words("Second thought.", from: 3, source: .system)
        let segments = TranscriptBuilder.segments(from: all)
        #expect(segments.count == 1)
        #expect(segments[0].text == "First thought. Second thought.")
    }

    @Test func splitsVeryLongTurns() {
        let all = words("one two", from: 0, source: .system)
            + words("three four", from: 50, source: .system)
            + words("five six", from: 100, source: .system)
        #expect(TranscriptBuilder.segments(from: all).count == 2)
    }

    @Test func removesMicrophoneEchoOfTheMeeting() {
        let system = words("The quarterly numbers look strong this time", from: 10, source: .system)
        let echo = words("the quarterly numbers look strong this", from: 10.2, source: .microphone)
        let reply = words("Great, I agree completely", from: 16, source: .microphone)
        let segments = TranscriptBuilder.segments(from: system + echo + reply)
        #expect(segments.map(\.source) == [.system, .microphone])
        #expect(segments[1].text == "Great, I agree completely")
    }

    @Test func keepsShortRepliesThatRepeatAWord() {
        let system = words("Can you hear me? Yes", from: 0, source: .system)
        let reply = words("Yes", from: 2, source: .microphone)
        let segments = TranscriptBuilder.segments(from: system + reply)
        #expect(segments.contains { $0.source == .microphone })
    }
}

struct TranscriptRendererTests {
    let metadata = TranscriptMetadata(
        title: "Weekly sync", platform: .googleMeet,
        startedAt: Date(timeIntervalSince1970: 1_789_000_000),
        microphoneLabel: "Mark", systemLabel: "Others")

    @Test func rendersSpeakerTurnsWithTimestamps() {
        let markdown = TranscriptRenderer.markdown(
            metadata: metadata,
            segments: [
                TranscriptSegment(source: .system, start: 3, end: 5, text: "Morning."),
                TranscriptSegment(source: .microphone, start: 3725, end: 3727, text: "Hi!"),
            ],
            duration: 3800, inProgress: false)
        #expect(markdown.contains("# Weekly sync"))
        #expect(markdown.contains("**[00:00:03] Others:** Morning."))
        #expect(markdown.contains("**[01:02:05] Mark:** Hi!"))
        #expect(markdown.contains("status: complete"))
        #expect(!markdown.contains("in progress"))
    }

    @Test func marksTranscriptsInProgress() {
        let markdown = TranscriptRenderer.markdown(metadata: metadata, segments: [], duration: 10, inProgress: true)
        #expect(markdown.contains("status: recording"))
        #expect(markdown.contains("_Transcription in progress…_"))
    }

    @Test func escapesQuotesInFrontMatter() {
        var quoted = metadata
        quoted.title = #"Say "hi""#
        let markdown = TranscriptRenderer.markdown(metadata: quoted, segments: [], duration: 0, inProgress: false)
        #expect(markdown.contains(#"title: "Say \"hi\"""#))
    }

    @Test func namesFilesByDateAndMeeting() {
        let name = TranscriptFileNamer.fileName(for: metadata)
        #expect(name.hasSuffix(" Google Meet - Weekly sync.md"))
        #expect(name.wholeMatch(of: #/\d{4}-\d{2}-\d{2} \d{4} .*/#) != nil)
    }

    @Test func sanitizesTitlesForTheFileSystem() {
        #expect(TranscriptFileNamer.sanitize("Q3: plan / review?") == "Q3 plan review")
    }

    @Test func neverOverwritesAnExistingTranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = TranscriptFileNamer.uniqueURL(in: directory, for: metadata)
        try Data().write(to: first)
        let second = TranscriptFileNamer.uniqueURL(in: directory, for: metadata)
        #expect(first != second)
        #expect(second.lastPathComponent.hasSuffix("Weekly sync 2.md"))
    }
}
