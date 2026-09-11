import Foundation
import Testing
@testable import TranscribeCore

struct ChunkAccumulatorTests {
    let rate = 1_000.0

    /// A tone with a silent gap at `gap` seconds, `length` seconds long.
    func speech(length: Double, gapAt gap: Double? = nil) -> [Float] {
        (0..<Int(length * rate)).map { i in
            let t = Double(i) / rate
            if let gap, abs(t - gap) < 0.1 { return 0 }
            return Float(sin(t * 2 * .pi * 100) * 0.5)
        }
    }

    @Test func cutsAtTheQuietestPointBeforeTheTarget() {
        var accumulator = ChunkAccumulator(source: .system, sampleRate: rate,
                                           targetDuration: 10, searchWindow: 3)
        let chunks = accumulator.append(speech(length: 12, gapAt: 8.5))
        #expect(chunks.count == 1)
        let chunk = chunks[0]
        #expect(chunk.startTime == 0)
        // Anywhere inside the silent gap (8.4–8.6 s) is a clean cut.
        #expect((8.4...8.6).contains(chunk.duration))
        #expect(abs(chunk.duration + accumulator.bufferedDuration - 12) < 1e-9)
    }

    @Test func chunksFollowOnWithoutGapsOrOverlap() {
        var accumulator = ChunkAccumulator(source: .microphone, sampleRate: rate,
                                           targetDuration: 5, searchWindow: 2)
        var chunks: [AudioChunk] = []
        let audio = speech(length: 23)
        for start in stride(from: 0, to: audio.count, by: 256) {
            chunks += accumulator.append(Array(audio[start..<min(start + 256, audio.count)]))
        }
        if let last = accumulator.flush() { chunks.append(last) }

        var expectedStart = 0.0
        for chunk in chunks {
            #expect(abs(chunk.startTime - expectedStart) < 1e-9)
            #expect(chunk.duration <= 5)
            expectedStart += chunk.duration
        }
        #expect(abs(expectedStart - 23) < 1e-9)
    }

    @Test func dropsSilentChunksButKeepsTheTimeline() {
        var accumulator = ChunkAccumulator(source: .system, sampleRate: rate,
                                           targetDuration: 5, searchWindow: 2)
        let silent = accumulator.append([Float](repeating: 0, count: 6_000))
        #expect(silent.isEmpty)
        let chunks = accumulator.append(speech(length: 5))
        #expect(chunks.count == 1)
        #expect(chunks[0].startTime >= 3)
    }

    @Test func resyncMovesTheTimelineForward() {
        var accumulator = ChunkAccumulator(source: .system, sampleRate: rate,
                                           targetDuration: 5, searchWindow: 2)
        _ = accumulator.append(speech(length: 1))
        let flushed = accumulator.resync(to: 60)
        #expect(flushed?.startTime == 0)
        #expect(abs((flushed?.duration ?? 0) - 1) < 1e-9)
        _ = accumulator.append(speech(length: 2))
        #expect(accumulator.flush()?.startTime == 60)
    }
}
