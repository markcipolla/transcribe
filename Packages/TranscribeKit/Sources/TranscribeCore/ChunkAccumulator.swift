import Foundation

/// A span of mono audio from one source, positioned on the recording timeline.
public struct AudioChunk: Sendable {
    public let source: AudioSource
    /// Seconds from the start of the recording to the first sample.
    public let startTime: TimeInterval
    public let samples: [Float]
    public let sampleRate: Double

    public init(source: AudioSource, startTime: TimeInterval, samples: [Float], sampleRate: Double) {
        self.source = source
        self.startTime = startTime
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval { Double(samples.count) / sampleRate }
}

/// Collects a live stream of samples and cuts it into chunks for transcription.
///
/// Voz has no streaming API, so live transcription means transcribing the
/// meeting in pieces as it happens. Cutting at a fixed length would split words
/// in half, so each cut lands on the quietest moment near the target length,
/// which in speech is almost always the gap between words.
public struct ChunkAccumulator: Sendable {
    public let source: AudioSource
    public let sampleRate: Double
    /// How long a chunk should be before it is cut.
    public let targetDuration: TimeInterval
    /// How far back from the target to look for a quiet place to cut.
    public let searchWindow: TimeInterval
    /// RMS level below which a 20 ms frame counts as silence.
    public let silenceLevel: Float
    /// Chunks with less than this much non-silent audio are dropped rather than
    /// transcribed. Mostly this skips the long stretches where the meeting audio
    /// is digital silence because nobody else is talking.
    public let minimumVoicedDuration: TimeInterval

    private var buffer: [Float] = []
    /// Timeline position of `buffer[0]`, in samples.
    private var bufferStart = 0

    public init(
        source: AudioSource,
        sampleRate: Double,
        targetDuration: TimeInterval = 30,
        searchWindow: TimeInterval = 6,
        silenceLevel: Float = 0.002,
        minimumVoicedDuration: TimeInterval = 0.3
    ) {
        precondition(searchWindow < targetDuration)
        self.source = source
        self.sampleRate = sampleRate
        self.targetDuration = targetDuration
        self.searchWindow = searchWindow
        self.silenceLevel = silenceLevel
        self.minimumVoicedDuration = minimumVoicedDuration
    }

    private var frameLength: Int { max(1, Int(sampleRate * 0.02)) }
    private var targetLength: Int { Int(targetDuration * sampleRate) }

    /// Seconds of audio waiting to be cut into a chunk.
    public var bufferedDuration: TimeInterval { Double(buffer.count) / sampleRate }

    /// Add samples that follow on directly from the previous ones, returning any
    /// chunks that are now complete.
    public mutating func append(_ samples: [Float]) -> [AudioChunk] {
        buffer.append(contentsOf: samples)
        var chunks: [AudioChunk] = []
        while buffer.count >= targetLength {
            let cut = quietestCut(in: (targetLength - Int(searchWindow * sampleRate))..<targetLength)
            if let chunk = take(cut) { chunks.append(chunk) }
        }
        return chunks
    }

    /// Emit whatever is buffered, however short.
    public mutating func flush() -> AudioChunk? {
        take(buffer.count)
    }

    /// Move to a new point on the timeline, after a gap in the audio such as a
    /// device change. Anything buffered is emitted first so it keeps its place.
    public mutating func resync(to time: TimeInterval) -> AudioChunk? {
        let chunk = flush()
        bufferStart = max(bufferStart, Int(time * sampleRate))
        return chunk
    }

    /// Remove the first `count` samples, returning them as a chunk unless they
    /// are silent.
    private mutating func take(_ count: Int) -> AudioChunk? {
        guard count > 0 else { return nil }
        let samples = Array(buffer[..<count])
        let start = Double(bufferStart) / sampleRate
        buffer.removeFirst(count)
        bufferStart += count
        guard voicedDuration(samples) >= minimumVoicedDuration else { return nil }
        return AudioChunk(source: source, startTime: start, samples: samples, sampleRate: sampleRate)
    }

    /// The sample index within `range` at the centre of the quietest frame.
    private func quietestCut(in range: Range<Int>) -> Int {
        let frame = frameLength
        var best = range.upperBound
        var bestEnergy = Float.greatestFiniteMagnitude
        var position = max(0, range.lowerBound)
        while position + frame <= range.upperBound {
            let energy = meanSquare(buffer[position..<(position + frame)])
            // `<=` prefers the latest of equally quiet frames, keeping chunks long.
            if energy <= bestEnergy {
                bestEnergy = energy
                best = position + frame / 2
            }
            position += frame
        }
        return max(1, best)
    }

    private func voicedDuration(_ samples: [Float]) -> TimeInterval {
        let frame = frameLength
        let threshold = silenceLevel * silenceLevel
        var voiced = 0
        var position = 0
        while position < samples.count {
            let end = min(position + frame, samples.count)
            if meanSquare(samples[position..<end]) > threshold { voiced += end - position }
            position = end
        }
        return Double(voiced) / sampleRate
    }

    private func meanSquare(_ slice: ArraySlice<Float>) -> Float {
        guard !slice.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in slice { sum += sample * sample }
        return sum / Float(slice.count)
    }
}
