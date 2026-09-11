import Foundation

/// A subject a transcript covers, from the topic tagger.
public struct TranscriptTopic: Sendable, Equatable {
    /// Stable identifier, such as `technology`. Written to the front matter as a tag.
    public let slug: String
    /// Display name, such as `Technology & Software`.
    public let name: String

    public init(slug: String, name: String) {
        self.slug = slug
        self.name = name
    }
}

/// Cuts a transcript into passages for topic tagging.
///
/// The tagger is trained on post-length text: a title, or a title and a
/// description. A meeting runs to thousands of words, and averaged over all of
/// them every topic blurs into the rest. So each passage is tagged on its own
/// and the results are rolled up, the way the tagger rolls up a channel's posts.
public enum TopicPassages {
    /// About a paragraph: long enough to have a subject, short enough to have one.
    public static let targetWords = 80
    /// Below this there is nothing to tag. "Can you hear me? One sec, my
    /// camera's broken" comes back as Music and Technology.
    public static let minimumWords = 50

    /// The transcript's words in order, split evenly into passages of about
    /// `targetWords`. Speaker turns are ignored; a topic does not care who
    /// raised it. Empty when there are fewer than `minimumWords`.
    public static func passages(from segments: [TranscriptSegment],
                                targetWords: Int = targetWords) -> [String] {
        let words = segments.flatMap { $0.text.split(whereSeparator: \.isWhitespace) }
        guard words.count >= minimumWords else { return [] }
        // An even split, rather than fixed-size passages, leaves no short
        // leftover at the end to be tagged on a handful of words.
        let count = max(1, Int((Double(words.count) / Double(targetWords)).rounded()))
        return (0..<count).map { index in
            let start = index * words.count / count
            let end = (index + 1) * words.count / count
            return words[start..<end].joined(separator: " ")
        }
    }
}
