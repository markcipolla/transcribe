import Foundation

/// The text a meeting's title and description are written from.
///
/// The title model was fine-tuned on short clips. Given a whole meeting it does
/// well up to around 8,000 words and then falls apart: past 12,000 it answered
/// with a heading such as "TRANSCRIPT" and no description. So a long meeting is
/// cut down to a few evenly spaced stretches of conversation, each taken from
/// the middle of its part of the meeting. That covers the whole meeting and
/// skips the greetings at the start and the goodbyes at the end.
public enum TitlePassage {
    /// Measured on AMI, ICSI and parliamentary meetings of 7,000 to 16,000
    /// words. At 1,200 words the title often named a single side topic, and at
    /// 5,000 the model sometimes broke down as it does on a whole meeting.
    public static let wordBudget = 3_000
    /// Long enough stretches that each reads as conversation, not fragments.
    public static let stretches = 4

    /// One line per speaker turn, without speaker labels: "Mark" and "Others"
    /// say nothing about the subject, and the model would work them into the
    /// title. Stretches are separated by a blank line.
    public static func text(from segments: [TranscriptSegment],
                            wordBudget: Int = wordBudget,
                            stretches: Int = stretches) -> String {
        let turns = segments.map { $0.text.split(whereSeparator: \.isWhitespace) }
        let total = turns.reduce(0) { $0 + $1.count }
        guard total > wordBudget, stretches > 0 else {
            return turns.filter { !$0.isEmpty }.map { $0.joined(separator: " ") }.joined(separator: "\n")
        }

        // Every word, tagged with the turn it came from, so a stretch can put
        // the line breaks back where the speakers changed.
        let words = turns.enumerated().flatMap { turn, words in words.map { (turn, $0) } }
        let length = wordBudget / stretches
        return (0..<stretches).map { index in
            let middle = total * (2 * index + 1) / (2 * stretches)
            let start = min(max(0, middle - length / 2), total - length)
            var lines: [[Substring]] = []
            var lastTurn: Int?
            for (turn, word) in words[start..<start + length] {
                if turn != lastTurn { lines.append([]) }
                lines[lines.count - 1].append(word)
                lastTurn = turn
            }
            return lines.map { $0.joined(separator: " ") }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

/// A meeting's title and a sentence or two about it, from the title model.
public struct MeetingSummary: Sendable, Equatable {
    public let title: String
    public let description: String

    /// Nil unless the model's reply looks like a title and a description. When
    /// it breaks down it writes a sentence or a bare heading as the title and
    /// no description, and a transcript is better with neither than with that.
    public init?(title: String, description: String) {
        let title = Self.clean(title).trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;: "))
        let description = Self.clean(description)
        let words = title.split(separator: " ").count
        guard (2...12).contains(words), !description.isEmpty else { return nil }
        self.title = title
        self.description = description
    }

    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”*"))
    }
}
