import Foundation

/// A transcript on disk, rewritten as new words arrive so the file is always
/// readable and a crash loses at most one chunk.
public actor TranscriptFile {
    public nonisolated let url: URL
    private var metadata: TranscriptMetadata
    private var words: [TranscribedWord] = []

    public init(url: URL, metadata: TranscriptMetadata) {
        self.url = url
        self.metadata = metadata
    }

    public var wordCount: Int { words.count }

    public var segments: [TranscriptSegment] { TranscriptBuilder.segments(from: words) }

    public func append(_ newWords: [TranscribedWord]) {
        words.append(contentsOf: newWords)
    }

    public func setTopics(_ topics: [TranscriptTopic]) {
        metadata.topics = topics
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
