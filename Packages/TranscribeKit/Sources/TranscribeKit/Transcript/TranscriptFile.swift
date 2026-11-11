import Foundation

/// A transcript on disk, rewritten as new words arrive so the file is always
/// readable and a crash loses at most one chunk.
public actor TranscriptFile {
    public private(set) var url: URL
    private var metadata: TranscriptMetadata
    private var words: [TranscribedWord] = []
    private var callSamples: [CallSample] = []
    private let myNames: [String]

    /// - Parameter myNames: your own names, never given to anyone else in the call.
    public init(url: URL, metadata: TranscriptMetadata, myNames: [String] = []) {
        self.url = url
        self.metadata = metadata
        self.myNames = myNames
    }

    public var wordCount: Int { words.count }
    public var systemWordCount: Int { words.count { $0.source == .system } }

    public var segments: [TranscriptSegment] {
        TranscriptBuilder.segments(from: words, callSamples: callSamples, myNames: myNames)
    }

    /// The call app's readings so far, which name the meeting audio's speakers.
    public func setCallSamples(_ samples: [CallSample]) {
        callSamples = samples
    }

    public func append(_ newWords: [TranscribedWord]) {
        words.append(contentsOf: newWords)
    }

    public func apply(_ summary: MeetingSummary) {
        metadata.apply(summary)
    }

    public func setTopics(_ topics: [TranscriptTopic]) {
        metadata.topics = topics
    }

    /// Rename the file, for a meeting that got its title after it started.
    public func move(to newURL: URL) throws {
        try FileManager.default.moveItem(at: url, to: newURL)
        url = newURL
    }

    public func write(duration: TimeInterval, inProgress: Bool) throws {
        let markdown = TranscriptRenderer.markdown(
            metadata: metadata,
            segments: segments,
            duration: duration,
            inProgress: inProgress)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: url, options: .atomic)
    }
}
