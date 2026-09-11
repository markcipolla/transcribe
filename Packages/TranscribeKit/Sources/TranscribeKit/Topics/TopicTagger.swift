import Foundation
import Gist

/// Works out what a meeting was about with [Gist](https://desertant.com/models/gist/),
/// an on-device topic tagger with a fixed set of 36 topics. One instance is
/// shared by every recording.
public final class TopicTagger: Sendable {
    /// The most topics a transcript is tagged with.
    public static let maxTopics = 3

    private let gist = Gist()

    public init() {}

    /// Download (about 74 MB, once) and load the model, so tagging is instant
    /// when a recording ends. Concurrent calls share one load.
    public func prepare() async throws {
        try await gist.download()
    }

    /// The transcript's main topics, most prominent first.
    ///
    /// Each passage is scored on its own, then the scores are rolled up across
    /// the meeting: a topic has to carry a real share of the whole
    /// conversation, so an aside does not tag the meeting.
    public func topics(for segments: [TranscriptSegment]) async throws -> [TranscriptTopic] {
        var names: [String: String] = [:]
        var passages: [PostTopics] = []
        for passage in TopicPassages.passages(from: segments) {
            // Every topic with its score. `scores(of:)` gives the same numbers
            // but not the display names.
            let scored = try await gist.classify(passage, topK: .max, threshold: 0)
            for topic in scored { names[topic.slug] = topic.name }
            passages.append(PostTopics(topics: Dictionary(uniqueKeysWithValues: scored.map { ($0.slug, $0.score) })))
        }
        return channelTopics(passages, options: RollupOptions(topN: Self.maxTopics, minPosts: 1))
            .filter { $0.postCount > 0 }
            .map { TranscriptTopic(slug: $0.slug, name: names[$0.slug] ?? $0.slug) }
    }
}
