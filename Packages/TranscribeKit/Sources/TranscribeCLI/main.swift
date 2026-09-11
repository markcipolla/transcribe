@preconcurrency import AVFoundation
import Foundation
import TranscribeKit

// Development tool for exercising the pipeline without the app:
//
//   transcribe-cli file <audio> [--as system|microphone] [--title]
//       Runs a file through the same chunking and transcription as a live
//       recording and prints the Markdown transcript, titled like the app's
//       with --title.
//   transcribe-cli detect
//       Prints the apps using the microphone and the meeting detected, if any.
//   transcribe-cli record <seconds> [directory]
//       Records system audio and the microphone, like the app does.
//   transcribe-cli title <transcript.md | text file>
//       Writes a title and description the way the app does when a meeting
//       ends.
//
// Titles need the MLX shaders, which only Xcode builds: for --title and
// `title`, build with `make cli` rather than `swift run`.

@MainActor
func transcribeFile(_ path: String, source: AudioSource, title: Bool) async throws {
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

    var metadata = TranscriptMetadata(title: title ? nil : url.deletingPathExtension().lastPathComponent,
                                      platform: .manual, startedAt: Date())
    let segments = TranscriptBuilder.segments(from: words)
    if title {
        let writer = try await downloadedTitleWriter()
        let started = Date()
        if let summary = await writer.describe(segments) {
            metadata.apply(summary)
        }
        print("Titled in \(String(format: "%.1f", Date().timeIntervalSince(started))) s\n")
    }
    print(TranscriptRenderer.markdown(metadata: metadata,
                                      segments: segments,
                                      duration: Double(samples.count) / rate,
                                      inProgress: false))
}

/// Title a transcript this app wrote, or any text file.
@MainActor
func title(_ path: String) async throws {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    // Transcript lines look like `**[00:01:02] Mark:** words`.
    let turns = text.split(separator: "\n").compactMap { line -> TranscriptSegment? in
        guard line.hasPrefix("**["), let end = line.range(of: ":** ") else { return nil }
        return TranscriptSegment(source: .system, start: 0, end: 0, text: String(line[end.upperBound...]))
    }
    let passage = turns.isEmpty ? text : TitlePassage.text(from: turns)
    let writer = try await downloadedTitleWriter()
    let started = Date()
    guard let summary = await writer.describe(passage: passage) else {
        throw CLIError("the model wrote no usable title")
    }
    print("""
        \(passage.split(whereSeparator: \.isWhitespace).count) words in, \
        \(String(format: "%.1f", Date().timeIntervalSince(started))) s

        Title: \(summary.title)
        Description: \(summary.description)
        """)
}

@MainActor
func downloadedTitleWriter() async throws -> TitleWriter {
    let writer = TitleWriter()
    if !writer.isDownloaded {
        print("Downloading the title model…")
        try await writer.download()
    }
    return writer
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
        try await transcribeFile(arguments[1], source: source, title: arguments.contains("--title"))
    case "title" where arguments.count >= 2:
        try await title(arguments[1])
    case "detect":
        await detect()
    case "record" where arguments.count >= 2:
        let directory = arguments.count >= 3
            ? URL(fileURLWithPath: arguments[2])
            : FileManager.default.temporaryDirectory
        try await record(seconds: Double(arguments[1]) ?? 10, directory: directory)
    default:
        print("usage: transcribe-cli file <audio> [--as microphone] [--title] | detect | record <seconds> [directory] | title <file>")
        exit(2)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
