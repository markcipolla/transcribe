import DesertAnt
import Foundation
import MLX
import Observation
import os
import Title

/// Names a finished meeting and describes it in a sentence or two, using
/// Desert Ant Labs' Title model on the GPU.
///
/// The model is loaded for each meeting and let go straight after. Loading
/// takes about a second, which is nothing next to a meeting, and keeping it
/// resident would cost the menu bar app several hundred megabytes all day.
@MainActor
@Observable
public final class TitleWriter {
    public enum State: Equatable, Sendable {
        /// Not on disk yet. Downloads via ``download()``.
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case failed(String)
    }

    public private(set) var state: State

    /// A newer model revision the Hub is offering. See
    /// ``TranscriptionEngine/newerRevision`` for the semantics.
    public private(set) var newerRevision: String?

    @ObservationIgnored private var downloadTask: Task<String, Error>?
    @ObservationIgnored private let log = Logger(subsystem: "Transcribe", category: "Titles")

    /// Where the verified model lives, remembered per model revision, so the
    /// SDK's checksum of every file runs once, at download, not on every use.
    private nonisolated static var modelPathKey: String { "titleModelPath.\(TitleModel.revision)" }

    private nonisolated static var verifiedModelPath: String? {
        guard let path = UserDefaults.standard.string(forKey: modelPathKey),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    public init() {
        state = Self.verifiedModelPath == nil ? .notDownloaded : .downloaded
    }

    public var isDownloaded: Bool { state == .downloaded }

    /// Download the model if it is not on disk. Safe to call repeatedly;
    /// concurrent callers share one download.
    public func download() async throws {
        if Self.verifiedModelPath != nil {
            state = .downloaded
            return
        }
        if let downloadTask {
            _ = try await downloadTask.value
            return
        }
        state = .downloading(progress: 0)
        let task = Task.detached(priority: .utility) { [weak self] () throws -> String in
            let model = try await TitleModel.resolve { progress in
                let fraction = progress.fraction
                Task { @MainActor in self?.downloadProgressed(fraction) }
            }
            UserDefaults.standard.set(model.rootPath, forKey: Self.modelPathKey)
            return model.rootPath
        }
        downloadTask = task
        defer { downloadTask = nil }
        do {
            _ = try await task.value
            state = .downloaded
            log.info("Title model downloaded")
        } catch {
            state = .failed(String(describing: error))
            log.error("Title model failed to download: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Ask the Hub whether a newer model revision exists within this SDK's
    /// major-version range, and remember it on ``newerRevision`` if so.
    public func checkForUpdate() async {
        let latest = await TitleModel.distribution
            .resolving(.from(TitleModel.revision)).revision
        newerRevision = latest == TitleModel.revision ? nil : latest
    }

    /// A title and description for a meeting, or nil when the model is not
    /// downloaded or wrote nothing usable.
    public func describe(_ segments: [TranscriptSegment]) async -> MeetingSummary? {
        await describe(passage: TitlePassage.text(from: segments))
    }

    /// A title and description for any text.
    public func describe(passage: String) async -> MeetingSummary? {
        guard let path = Self.verifiedModelPath, !passage.isEmpty else { return nil }
        let started = Date()
        let result = await Task.detached(priority: .userInitiated) {
            try await Self.generate(passage, modelPath: path)
        }.result
        switch result {
        case .success(let card):
            log.info("Titled in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
            guard let summary = MeetingSummary(title: card.title, description: card.description) else {
                log.error("Unusable title: \(card.title, privacy: .private)")
                return nil
            }
            return summary
        case .failure(let error):
            // Most likely the files on disk are damaged. Forget them, so the
            // next recording checks them again and fetches what is missing.
            log.error("Title failed: \(String(describing: error), privacy: .public)")
            UserDefaults.standard.removeObject(forKey: Self.modelPathKey)
            state = .notDownloaded
            return nil
        }
    }

    /// Load, generate, and release. By the time this returns the model's
    /// weights are back in MLX's buffer cache, which is then emptied.
    private nonisolated static func generate(_ passage: String, modelPath: String) async throws -> Card {
        defer { Memory.clearCache() }
        return try await Titles(directory: URL(fileURLWithPath: modelPath)).describe(passage)
    }

    private func downloadProgressed(_ fraction: Double) {
        guard case .downloading(let current) = state,
              fraction - current >= 0.005 || fraction >= 1 else { return }
        state = .downloading(progress: fraction)
    }
}
