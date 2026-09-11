import Foundation
import Observation
import os

/// One recording, from start to finished transcript.
///
/// Both sources are captured, cut into chunks and transcribed while the
/// meeting is still going, and the transcript file is rewritten after every
/// chunk. Stopping only has to transcribe the last few seconds.
@MainActor
@Observable
public final class RecordingSession {
    public enum State: Equatable, Sendable {
        case recording
        /// Capture has stopped; the last chunks are being transcribed.
        case finishing
        case finished
    }

    /// Gains a title and description when the recording is finished.
    public private(set) var metadata: TranscriptMetadata
    /// Changes when a written title renames the file.
    public private(set) var fileURL: URL
    public private(set) var state: State = .recording
    public private(set) var endedAt: Date?
    /// Problems worth showing, such as a chunk that failed to transcribe.
    public private(set) var warnings: [String] = []
    public private(set) var chunksTranscribed = 0
    /// Set when the recording ended without any speech and its file was deleted.
    public private(set) var wasDiscarded = false
    public let capturesMicrophone: Bool

    public var startedAt: Date { metadata.startedAt }
    public var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    @ObservationIgnored private let engine: TranscriptionEngine
    @ObservationIgnored private let tagger: TopicTagger?
    @ObservationIgnored private let titleWriter: TitleWriter?
    @ObservationIgnored private let file: TranscriptFile
    @ObservationIgnored private let router: ChunkRouter
    @ObservationIgnored private var microphone: MicrophoneCapture?
    @ObservationIgnored private var system: SystemAudioCapture?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "Transcribe", category: "Session")

    /// Chunk length. Long enough to give the model context, short enough that
    /// the file on disk trails the meeting by under a minute.
    public static let chunkDuration: TimeInterval = 30

    /// - Parameters:
    ///   - tagger: tags the transcript with its topics once the meeting ends.
    ///     Nil leaves it untagged.
    ///   - titleWriter: names and describes the meeting once it ends.
    ///     Nil leaves the transcript as it was started.
    public init(
        metadata: TranscriptMetadata,
        directory: URL,
        captureMicrophone: Bool,
        engine: TranscriptionEngine,
        tagger: TopicTagger? = nil,
        titleWriter: TitleWriter? = nil
    ) {
        self.metadata = metadata
        self.engine = engine
        self.tagger = tagger
        self.titleWriter = titleWriter
        self.capturesMicrophone = captureMicrophone
        let fileURL = TranscriptFileNamer.uniqueURL(in: directory, for: metadata)
        self.fileURL = fileURL
        file = TranscriptFile(url: fileURL, metadata: metadata)
        router = ChunkRouter(startedAt: metadata.startedAt,
                             sampleRate: TranscriptionEngine.sampleRate,
                             chunkDuration: Self.chunkDuration)
    }

    /// Start capturing. Throws if the meeting audio cannot be captured; a
    /// microphone that cannot start is recorded as a warning instead, since the
    /// other participants are still worth having.
    public func start() async throws {
        let router = self.router
        let system = SystemAudioCapture(
            sampleRate: TranscriptionEngine.sampleRate,
            onSamples: { router.ingest($0, from: .system) },
            onRestart: { router.sourceRestarted(.system) },
            onFailure: { [weak self] error in
                Task { @MainActor in
                    self?.warnings.append("Meeting audio stopped after an output device change: \(error)")
                }
            })
        try system.start()
        self.system = system

        if capturesMicrophone {
            let microphone = MicrophoneCapture(
                sampleRate: TranscriptionEngine.sampleRate,
                onSamples: { router.ingest($0, from: .microphone) },
                onRestart: { router.sourceRestarted(.microphone) },
                onFailure: { [weak self] error in
                    Task { @MainActor in
                        self?.warnings.append("The microphone stopped after an input device change: \(error)")
                    }
                })
            do {
                if await MicrophoneCapture.requestAccess() {
                    try microphone.start()
                    self.microphone = microphone
                } else {
                    warnings.append("Microphone access is off, so only the other participants are transcribed.")
                }
            } catch {
                warnings.append("The microphone could not start: \(error)")
            }
        }

        try? await file.write(duration: 0, inProgress: true)
        consumer = Task { await self.transcribeChunks() }
        log.info("Recording \(self.metadata.displayTitle, privacy: .public) to \(self.fileURL.path, privacy: .public)")
    }

    /// Stop capturing, transcribe what is left, and finish the file.
    public func stop() async {
        guard state == .recording else { return }
        state = .finishing
        endedAt = Date()
        microphone?.stop()
        system?.stop()
        microphone = nil
        system = nil
        router.finish()
        await consumer?.value
        if await file.wordCount == 0 {
            // Nobody spoke: a Meet lobby you looked at and left, say. An empty
            // transcript is clutter, so it goes.
            try? FileManager.default.removeItem(at: fileURL)
            wasDiscarded = true
            log.info("No speech; discarded \(self.fileURL.lastPathComponent, privacy: .public)")
        } else {
            await writeTitle()
            do {
                // Saved before tagging, so a topic model that is still
                // downloading cannot hold up the transcript.
                try await file.write(duration: duration, inProgress: false)
                if await tagTopics() {
                    try await file.write(duration: duration, inProgress: false)
                }
            } catch {
                warnings.append("The transcript could not be saved: \(error.localizedDescription)")
            }
            log.info("Finished \(self.fileURL.lastPathComponent, privacy: .public)")
        }
        state = .finished
    }

    /// Title and describe the finished meeting, renaming the file when the
    /// title is new. Takes a second or two; without the model it does nothing.
    private func writeTitle() async {
        guard let titleWriter,
              let summary = await titleWriter.describe(await file.segments) else { return }
        let old = metadata
        metadata.apply(summary)
        await file.apply(summary)
        guard TranscriptFileNamer.fileName(for: metadata) != TranscriptFileNamer.fileName(for: old) else { return }
        let renamed = TranscriptFileNamer.uniqueURL(in: fileURL.deletingLastPathComponent(), for: metadata)
        do {
            try await file.move(to: renamed)
            fileURL = renamed
        } catch {
            // The title is still inside the file; only the name is generic.
            log.error("Could not rename to \(renamed.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// When a source last delivered sound, so the UI can show that audio is
    /// actually arriving (a missing permission shows up as silence).
    public func lastHeard(_ source: AudioSource) -> Date? {
        router.lastHeard(source)
    }

    /// Add the meeting's topics to the transcript. Returns whether any were
    /// found. Topics are a nicety, so failing to find them is only logged.
    private func tagTopics() async -> Bool {
        guard let tagger else { return false }
        do {
            let topics = try await tagger.topics(for: await file.segments)
            log.info("Topics: \(topics.map(\.slug).joined(separator: ", "), privacy: .public)")
            guard !topics.isEmpty else { return false }
            await file.setTopics(topics)
            return true
        } catch {
            log.error("Topic tagging failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func transcribeChunks() async {
        for await chunk in router.chunks {
            do {
                let words = try await engine.transcribe(chunk)
                await file.append(words)
                chunksTranscribed += 1
                try await file.write(duration: duration, inProgress: state == .recording)
            } catch {
                let time = TranscriptRenderer.timestamp(chunk.startTime)
                warnings.append("Audio at \(time) could not be transcribed: \(error)")
                log.error("Chunk at \(time, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
