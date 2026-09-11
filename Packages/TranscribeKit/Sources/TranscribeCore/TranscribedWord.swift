import Foundation

/// Where a piece of audio came from. Each source is transcribed separately,
/// which is what lets the transcript say who was talking without diarization:
/// the microphone is you, the meeting audio is everyone else.
public enum AudioSource: String, Sendable, Codable, CaseIterable {
    case microphone
    case system
}

/// A recognised word placed on the recording's timeline, in seconds from the
/// moment recording started.
public struct TranscribedWord: Sendable, Equatable, Codable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let source: AudioSource

    public init(text: String, start: TimeInterval, end: TimeInterval, source: AudioSource) {
        self.text = text
        self.start = start
        self.end = max(start, end)
        self.source = source
    }
}
