import Foundation
import os

/// Receives samples from the capture threads and turns them into chunks on a
/// stream, keeping both sources on one timeline.
///
/// Each source's position is counted in samples, which is exact, but the two
/// sources start at slightly different moments and may restart after device
/// changes. So the first samples of a source, and the first after a restart,
/// are placed by the wall clock.
final class ChunkRouter: Sendable {
    private struct State {
        var accumulators: [AudioSource: ChunkAccumulator]
        var needsResync: Set<AudioSource> = Set(AudioSource.allCases)
        var lastHeard: [AudioSource: Date] = [:]
        var finished = false
    }

    let chunks: AsyncStream<AudioChunk>
    private let continuation: AsyncStream<AudioChunk>.Continuation
    private let state: OSAllocatedUnfairLock<State>
    private let startedAt: Date
    private let sampleRate: Double
    /// Level above which a buffer counts as sound, for ``lastHeard(_:)``.
    private let audibleLevel: Float = 0.003

    init(startedAt: Date, sampleRate: Double, chunkDuration: TimeInterval) {
        self.startedAt = startedAt
        self.sampleRate = sampleRate
        (chunks, continuation) = AsyncStream<AudioChunk>.makeStream()
        var accumulators: [AudioSource: ChunkAccumulator] = [:]
        for source in AudioSource.allCases {
            accumulators[source] = ChunkAccumulator(source: source, sampleRate: sampleRate,
                                                    targetDuration: chunkDuration)
        }
        state = OSAllocatedUnfairLock(initialState: State(accumulators: accumulators))
    }

    func ingest(_ samples: [Float], from source: AudioSource) {
        let now = Date()
        let audible = samples.contains { abs($0) > audibleLevel }
        let ready: [AudioChunk] = state.withLock { state in
            guard !state.finished, var accumulator = state.accumulators[source] else { return [] }
            var ready: [AudioChunk] = []
            if state.needsResync.remove(source) != nil {
                // These samples ended just now, so they started their length ago.
                let start = now.timeIntervalSince(startedAt) - Double(samples.count) / sampleRate
                if let flushed = accumulator.resync(to: max(0, start)) { ready.append(flushed) }
            }
            ready += accumulator.append(samples)
            state.accumulators[source] = accumulator
            if audible { state.lastHeard[source] = now }
            return ready
        }
        for chunk in ready { continuation.yield(chunk) }
    }

    /// A source restarted and there may be a gap in its samples.
    func sourceRestarted(_ source: AudioSource) {
        state.withLock { _ = $0.needsResync.insert(source) }
    }

    /// When a source last delivered something louder than silence.
    func lastHeard(_ source: AudioSource) -> Date? {
        state.withLock { $0.lastHeard[source] }
    }

    /// Emit what is buffered and end the stream.
    func finish() {
        let remaining: [AudioChunk] = state.withLock { state in
            guard !state.finished else { return [] }
            state.finished = true
            return AudioSource.allCases.compactMap { state.accumulators[$0]?.flush() }
        }
        for chunk in remaining { continuation.yield(chunk) }
        continuation.finish()
    }
}
