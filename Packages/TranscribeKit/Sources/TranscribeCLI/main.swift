@preconcurrency import AVFoundation
import Foundation
import TranscribeKit

// Development tool for exercising the pipeline without the app:
//
//   transcribe-cli file <audio> [--as system|microphone]
//       Runs a file through the same chunking and transcription as a live
//       recording and prints the Markdown transcript.
//   transcribe-cli detect
//       Prints the apps using the microphone and the meeting detected, if any.
//   transcribe-cli record <seconds> [directory]
//       Records system audio and the microphone, like the app does.

@MainActor
func transcribeFile(_ path: String, source: AudioSource) async throws {
    let url = URL(fileURLWithPath: path)
    let file = try AVAudioFile(forReading: url)
    let rate = TranscriptionEngine.sampleRate
    guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                     channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: file.processingFormat, to: output)
    else { throw CLIError("cannot convert \(path)") }
    converter.downmix = true

    // Decode the whole file, then feed it in capture-sized buffers.
    let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                 frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: input)
    let converted = AVAudioPCMBuffer(
        pcmFormat: output,
        frameCapacity: AVAudioFrameCount(Double(file.length) * rate / file.processingFormat.sampleRate) + 4096)!
    nonisolated(unsafe) var fed = false
    var error: NSError?
    converter.convert(to: converted, error: &error) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true
        status.pointee = .haveData
        return input
    }
    if let error { throw error }
    let samples = Array(UnsafeBufferPointer(start: converted.floatChannelData![0],
                                            count: Int(converted.frameLength)))
    print("Decoded \(String(format: "%.1f", Double(samples.count) / rate)) s")

    let engine = TranscriptionEngine()
    let loadStart = Date()
    try await engine.load()
    print("Model loaded in \(String(format: "%.1f", Date().timeIntervalSince(loadStart))) s")

    var accumulator = ChunkAccumulator(source: source, sampleRate: rate,
                                       targetDuration: RecordingSession.chunkDuration)
    var chunks: [AudioChunk] = []
    for start in stride(from: 0, to: samples.count, by: 4096) {
        chunks += accumulator.append(Array(samples[start..<min(start + 4096, samples.count)]))
    }
    if let last = accumulator.flush() { chunks.append(last) }

    var words: [TranscribedWord] = []
    let transcribeStart = Date()
    for chunk in chunks {
        print("  chunk \(String(format: "%6.1f", chunk.startTime))s +\(String(format: "%.1f", chunk.duration))s")
        words += try await engine.transcribe(chunk)
    }
    let elapsed = Date().timeIntervalSince(transcribeStart)
    print("Transcribed in \(String(format: "%.2f", elapsed)) s (\(String(format: "%.0f", Double(samples.count) / rate / elapsed))x realtime)\n")

    let metadata = TranscriptMetadata(title: url.deletingPathExtension().lastPathComponent,
                                      platform: .manual, startedAt: Date())
    print(TranscriptRenderer.markdown(metadata: metadata,
                                      segments: TranscriptBuilder.segments(from: words),
                                      duration: Double(samples.count) / rate,
                                      inProgress: false))
}

func detect() async {
    print("Processes using the microphone:")
    for process in AudioProcessList.usingMicrophone() {
        print("  pid \(process.pid)  \(process.bundleID)  (app: \(process.appBundleID))")
    }
    if let meeting = await MeetingDetector().detect() {
        print("Meeting: \(meeting.platform.rawValue) in \(meeting.appName)\(meeting.title.map { " — \($0)" } ?? "")")
    } else {
        print("No meeting detected.")
    }
}

@MainActor
func record(seconds: Double, directory: URL) async throws {
    let engine = TranscriptionEngine()
    let session = RecordingSession(
        metadata: TranscriptMetadata(title: "CLI test", platform: .manual, startedAt: Date()),
        directory: directory, captureMicrophone: true, engine: engine)
    try await session.start()
    print("Recording for \(Int(seconds)) s to \(session.fileURL.path)")
    try await Task.sleep(for: .seconds(seconds))
    await session.stop()
    for warning in session.warnings { print("warning: \(warning)") }
    print(try String(contentsOf: session.fileURL, encoding: .utf8))
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "file" where arguments.count >= 2:
        let source: AudioSource = arguments.contains("microphone") ? .microphone : .system
        try await transcribeFile(arguments[1], source: source)
    case "detect":
        await detect()
    case "record" where arguments.count >= 2:
        let directory = arguments.count >= 3
            ? URL(fileURLWithPath: arguments[2])
            : FileManager.default.temporaryDirectory
        try await record(seconds: Double(arguments[1]) ?? 10, directory: directory)
    default:
        print("usage: transcribe-cli file <audio> [--as microphone] | detect | record <seconds> [directory]")
        exit(2)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
