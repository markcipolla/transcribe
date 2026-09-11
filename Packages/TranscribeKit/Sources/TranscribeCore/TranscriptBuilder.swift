import Foundation

/// One speaker's turn: consecutive words from one source.
public struct TranscriptSegment: Sendable, Equatable {
    public let source: AudioSource
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(source: AudioSource, start: TimeInterval, end: TimeInterval, text: String) {
        self.source = source
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Turns the words from both sources into an interleaved conversation.
public enum TranscriptBuilder {
    /// A pause at least this long ends a turn.
    public static let turnPause: TimeInterval = 1.5
    /// Consecutive turns from the same speaker are merged up to this length.
    public static let maxTurnDuration: TimeInterval = 90

    public static func segments(from words: [TranscribedWord]) -> [TranscriptSegment] {
        let system = words.filter { $0.source == .system }
        let microphone = removeEcho(from: words.filter { $0.source == .microphone }, heardIn: system)
        let turns = (split(system) + split(microphone)).sorted { $0.start < $1.start }
        return mergeConsecutive(turns)
    }

    /// Break one source's words into turns at pauses.
    static func split(_ words: [TranscribedWord]) -> [TranscriptSegment] {
        let words = words.sorted { $0.start < $1.start }
        var segments: [TranscriptSegment] = []
        var current: [TranscribedWord] = []

        func close() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(TranscriptSegment(source: first.source, start: first.start,
                                              end: last.end, text: join(current)))
            current = []
        }

        for word in words {
            if let last = current.last, word.start - last.end >= turnPause { close() }
            current.append(word)
        }
        close()
        return segments
    }

    /// Join adjacent turns from the same speaker, so a speaker who pauses to
    /// think does not produce a new heading for every sentence.
    static func mergeConsecutive(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var merged: [TranscriptSegment] = []
        for segment in segments {
            if let last = merged.last, last.source == segment.source,
               segment.end - last.start <= maxTurnDuration {
                merged[merged.count - 1] = TranscriptSegment(
                    source: last.source, start: last.start, end: max(last.end, segment.end),
                    text: last.text + " " + segment.text)
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    /// Drop microphone words that are the meeting audio leaking back in.
    ///
    /// On speakers rather than headphones, the microphone hears the other
    /// participants too, and their words would appear twice: once as them and
    /// once as you. Each microphone turn is compared with what the meeting audio
    /// said at the same moment, and dropped when it is mostly the same words.
    static func removeEcho(from microphone: [TranscribedWord],
                           heardIn system: [TranscribedWord]) -> [TranscribedWord] {
        guard !system.isEmpty else { return microphone }
        let slack: TimeInterval = 2
        var kept: [TranscribedWord] = []
        for turn in splitWords(microphone) {
            guard let first = turn.first, let last = turn.last else { continue }
            let nearby = Set(system
                .filter { $0.end >= first.start - slack && $0.start <= last.end + slack }
                .map { normalize($0.text) })
            let tokens = turn.map { normalize($0.text) }.filter { !$0.isEmpty }
            guard !tokens.isEmpty else { continue }
            let matched = tokens.filter(nearby.contains).count
            let ratio = Double(matched) / Double(tokens.count)
            // Short turns need to match completely: "yes" answering "yes?" is real.
            let isEcho = tokens.count >= 3 ? ratio >= 0.6 : ratio == 1 && tokens.count > 1
            if !isEcho { kept.append(contentsOf: turn) }
        }
        return kept
    }

    private static func splitWords(_ words: [TranscribedWord]) -> [[TranscribedWord]] {
        let words = words.sorted { $0.start < $1.start }
        var turns: [[TranscribedWord]] = []
        for word in words {
            if let last = turns.last?.last, word.start - last.end < turnPause {
                turns[turns.count - 1].append(word)
            } else {
                turns.append([word])
            }
        }
        return turns
    }

    static func normalize(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func join(_ words: [TranscribedWord]) -> String {
        words.map(\.text).joined(separator: " ")
    }
}
