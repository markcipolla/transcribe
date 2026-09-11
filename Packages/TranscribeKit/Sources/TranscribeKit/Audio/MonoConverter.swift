@preconcurrency import AVFoundation

/// Downmixes and resamples captured audio to the mono rate the model wants.
///
/// Voz will resample by itself, but only linearly and only once it has the
/// whole chunk. Converting as audio arrives uses Core Audio's proper resampler
/// and keeps what is buffered at a quarter of the size of 48 kHz stereo.
final class MonoConverter {
    let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(from inputFormat: AVAudioFormat, sampleRate: Double) {
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: sampleRate,
                                               channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { return nil }
        // Without this a multichannel input keeps only its first channel.
        converter.downmix = true
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    /// Convert one buffer. The converter keeps state between calls, so a
    /// stream converted buffer by buffer stays continuous across the joins.
    func convert(_ input: AVAudioPCMBuffer) -> [Float] {
        guard input.frameLength > 0 else { return [] }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return []
        }
        // Runs synchronously inside `convert`, on this thread.
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
