import DesertAnt
import Foundation
import Observation
import os
import Voz

/// Owns the Voz speech model: downloading it, loading it, and transcribing
/// chunks with it. One instance is shared by every recording.
@MainActor
@Observable
public final class TranscriptionEngine {
    public enum State: Equatable, Sendable {
        /// Not on disk yet. Downloads on first use, or via ``load()``.
        case notDownloaded
        /// On disk, not in memory.
        case downloaded
        case downloading(progress: Double)
        /// Loading into the Neural Engine. The first load after a download
        /// specialises the model for this Mac, which takes about 20 seconds.
        case loading
        case ready
        case failed(String)
    }

    /// Sample rate of the audio this engine is fed. Voz's own rate, so chunks
    /// reach the model without resampling.
    public nonisolated static let sampleRate: Double = 16_000

    public private(set) var state: State

    /// A newer model revision the Hub is offering, when one exists and shares
    /// the SDK's major version. Set by ``checkForUpdate()``. The model itself
    /// ships bundled with the app; the download arrives with the next app
    /// update rather than being fetched from here.
    public private(set) var newerRevision: String?

    @ObservationIgnored private var loadTask: Task<Voz, Error>?
    @ObservationIgnored private let log = Logger(subsystem: "Transcribe", category: "Engine")

    /// Where the verified model lives, remembered per model revision.
    ///
    /// The SDK's own availability check and its loading initializer both
    /// SHA-256 the whole 467 MB model on every call: a second or two in a
    /// release build, minutes in a debug one, and far too slow for the main
    /// thread. So the model is verified once, when it is downloaded, and later
    /// launches load it straight from this directory.
    private nonisolated static var modelPathKey: String { "vozModelPath.\(VozModel.revision)" }

    private nonisolated static var verifiedModelPath: String? {
        guard let path = UserDefaults.standard.string(forKey: modelPathKey),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    public init() {
        state = Self.verifiedModelPath == nil ? .notDownloaded : .downloaded
    }

    public var isReady: Bool { state == .ready }

    /// Download the model if needed and load it. Safe to call repeatedly;
    /// concurrent callers share one load.
    @discardableResult
    public func load() async throws -> Voz {
        if let loadTask { return try await loadTask.value }
        state = .loading
        let log = self.log
        let task = Task.detached(priority: .userInitiated) { [weak self] () throws -> Voz in
            if let path = Self.verifiedModelPath {
                do {
                    return try Voz(modelDirectory: URL(fileURLWithPath: path))
                } catch {
                    log.error("Cached model failed to load, verifying it again: \(String(describing: error), privacy: .public)")
                }
            }
            // Downloads what is missing and verifies everything. Reports full
            // progress at once when the model is already intact.
            let root = try await Voz.download { progress in
                let fraction = progress.fraction
                Task { @MainActor in self?.downloadProgressed(fraction) }
            }
            UserDefaults.standard.set(root, forKey: Self.modelPathKey)
            return try Voz(modelDirectory: URL(fileURLWithPath: root))
        }
        loadTask = task
        do {
            let voz = try await task.value
            state = .ready
            log.info("Voz loaded")
            return voz
        } catch {
            loadTask = nil
            state = .failed(String(describing: error))
            log.error("Voz failed to load: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Ask the Hub whether a newer model revision exists within this SDK's
    /// major-version range, and remember it on ``newerRevision`` if so. Silent
    /// on network failure (the SDK falls the request back to the pinned
    /// revision, so a failed check reads as "no update").
    public func checkForUpdate() async {
        let latest = await VozModel.distribution
            .resolving(.from(VozModel.revision)).revision
        newerRevision = latest == VozModel.revision ? nil : latest
    }

    /// Transcribe one chunk, placing its words on the recording timeline.
    public func transcribe(_ chunk: AudioChunk) async throws -> [TranscribedWord] {
        let voz = try await load()
        // A word that runs right up to the end of the audio tends to be dropped,
        // so give the model a moment of silence to finish on.
        let padded = chunk.samples + [Float](repeating: 0, count: Int(chunk.sampleRate * 0.5))
        let result = try await voz.transcribe(samples: padded, sampleRate: chunk.sampleRate)
        log.debug("Transcribed \(chunk.duration, format: .fixed(precision: 1)) s of \(chunk.source.rawValue) at \(result.realtimeFactor, format: .fixed(precision: 0))x realtime")
        return result.words.map {
            TranscribedWord(text: $0.text,
                            start: chunk.startTime + $0.start,
                            end: chunk.startTime + $0.end,
                            source: chunk.source)
        }
    }

    private func downloadProgressed(_ fraction: Double) {
        switch state {
        case .loading where fraction < 1:
            state = .downloading(progress: fraction)
        case .downloading(let current) where fraction - current >= 0.005 || fraction >= 1:
            // Once the files are down, the remaining time is the load itself.
            state = fraction >= 1 ? .loading : .downloading(progress: fraction)
        default:
            break
        }
    }
}
