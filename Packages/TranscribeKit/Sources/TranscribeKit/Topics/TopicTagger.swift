import Foundation
import Gist
import Observation
import os

/// Works out what a meeting was about with [Gist](https://desertant.com/models/gist/),
/// an on-device topic tagger with a fixed set of 36 topics. One instance is
/// shared by every recording.
@MainActor
@Observable
public final class TopicTagger {
    /// The most topics a transcript is tagged with.
    public static let maxTopics = 3

    public private(set) var state: ModelDownloadState

    @ObservationIgnored private let gist = Gist()
    @ObservationIgnored private let log = Logger(subsystem: "Transcribe", category: "Topics")

    /// Set once the model is on disk, per model revision. The SDK's own check,
    /// `Gist.isDownloaded()`, checksums all 74 MB, too slow for the main
    /// thread every time Settings opens.
    private nonisolated static var downloadedKey: String { "gistDownloaded.\(GistModel.revision)" }

    public init() {
        if UserDefaults.standard.bool(forKey: Self.downloadedKey) {
            state = .downloaded
        } else {
            state = .notDownloaded
            // 0.2.0 downloaded the model without noting it here.
            Task { await findDownloadedModel() }
        }
    }

    public var isDownloaded: Bool { state == .downloaded }

    /// Download (about 74 MB, once) and load the model, so tagging is instant
    /// when a recording ends. Safe to call repeatedly: concurrent calls share
    /// one load, and once loaded it does nothing.
    public func download() async throws {
        switch state {
        case .notDownloaded, .failed: state = .downloading(progress: 0)
        case .downloading, .downloaded: break
        }
        do {
            try await gist.download { [weak self] fraction in
                Task { @MainActor in self?.downloadProgressed(fraction) }
            }
        } catch {
            state = .failed(String(describing: error))
            log.error("Topic model failed to load: \(String(describing: error), privacy: .public)")
            throw error
        }
        if !isDownloaded { log.info("Topic model downloaded") }
        UserDefaults.standard.set(true, forKey: Self.downloadedKey)
        state = .downloaded
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

    /// Checksum a model already in the cache, off the main thread, and note it.
    private func findDownloadedModel() async {
        let gist = self.gist
        let onDisk = await Task.detached(priority: .utility) { gist.isDownloaded() }.value
        guard onDisk, state == .notDownloaded else { return }
        UserDefaults.standard.set(true, forKey: Self.downloadedKey)
        state = .downloaded
    }

    private func downloadProgressed(_ fraction: Double) {
        guard case .downloading(let current) = state,
              fraction - current >= 0.005 || fraction >= 1 else { return }
        state = .downloading(progress: fraction)
    }
}
