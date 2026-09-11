import Foundation

/// What is known about a recording apart from its words.
public struct TranscriptMetadata: Sendable, Equatable {
    public var title: String?
    /// A sentence or two about the meeting, written once it has ended.
    public var description: String?
    public var platform: MeetingPlatform
    public var startedAt: Date
    /// Label for the microphone speaker, usually your name.
    public var microphoneLabel: String
    /// Label for everyone heard through the meeting audio.
    public var systemLabel: String
    /// What the meeting was about, most prominent first. Worked out once the
    /// recording ends, so empty until then.
    public var topics: [TranscriptTopic]

    public init(title: String?, platform: MeetingPlatform, startedAt: Date,
                microphoneLabel: String = "Me", systemLabel: String = "Others",
                topics: [TranscriptTopic] = []) {
        self.title = title
        self.platform = platform
        self.startedAt = startedAt
        self.microphoneLabel = microphoneLabel
        self.systemLabel = systemLabel
        self.topics = topics
    }

    /// The heading: the meeting's name, else the platform it was on.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return platform == .manual ? "Recording" : platform.rawValue
    }

    func label(for source: AudioSource) -> String {
        source == .microphone ? microphoneLabel : systemLabel
    }

    /// Add a written title and description. A meeting that already has a name
    /// keeps it, since that is what the people in it called it.
    public mutating func apply(_ summary: MeetingSummary) {
        if title?.isEmpty ?? true { title = summary.title }
        description = summary.description
    }
}

/// Renders a transcript as Markdown, with YAML front matter so tools such as
/// Obsidian can index it.
public enum TranscriptRenderer {
    public static func markdown(
        metadata: TranscriptMetadata,
        segments: [TranscriptSegment],
        duration: TimeInterval,
        inProgress: Bool
    ) -> String {
        let description = metadata.description.flatMap { $0.isEmpty ? nil : $0 }
        let topics = metadata.topics
        var lines: [String] = ["---", "title: \(yamlString(metadata.displayTitle))"]
        if let description { lines.append("description: \(yamlString(description))") }
        lines += [
            "date: \(iso8601(metadata.startedAt))",
            "platform: \(yamlString(metadata.platform.rawValue))",
            "duration: \(Int(duration.rounded()))",
            "status: \(inProgress ? "recording" : "complete")",
        ]
        if !topics.isEmpty {
            // Slugs are lowercase letters and hyphens, which are valid tags
            // as they are.
            lines.append("tags: [\(topics.map(\.slug).joined(separator: ", "))]")
        }
        lines += [
            "---",
            "",
            "# \(metadata.displayTitle)",
            "",
        ]
        if let description { lines += [description, ""] }
        lines += [
            "- **Date:** \(longDate(metadata.startedAt))",
            "- **Platform:** \(metadata.platform.rawValue)",
            "- **Duration:** \(humanDuration(duration))",
            "- **Speakers:** \(metadata.microphoneLabel) (microphone), \(metadata.systemLabel) (meeting audio)",
        ]
        if !topics.isEmpty {
            lines.append("- **Topics:** \(topics.map(\.name).joined(separator: ", "))")
        }
        lines += [
            "",
            "---",
            "",
        ]
        for segment in segments {
            lines.append("**[\(timestamp(segment.start))] \(metadata.label(for: segment.source)):** \(segment.text)")
            lines.append("")
        }
        if inProgress {
            lines.append("_Transcription in progress…_")
            lines.append("")
        } else if segments.isEmpty {
            lines.append("_No speech was detected._")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// `hh:mm:ss` from the start of the recording.
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    static func humanDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

    private static func longDate(_ date: Date) -> String {
        date.formatted(date: .complete, time: .shortened)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private static func yamlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Chooses where a transcript is saved.
public enum TranscriptFileNamer {
    /// `2026-09-11 0930 Google Meet - Weekly sync.md`, sortable by date.
    public static func fileName(for metadata: TranscriptMetadata) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        var name = formatter.string(from: metadata.startedAt) + " " + metadata.platform.rawValue
        if let title = metadata.title.map(sanitize), !title.isEmpty {
            name += " - " + title
        }
        return name + ".md"
    }

    /// A URL in `directory` for `metadata` that does not overwrite anything.
    public static func uniqueURL(in directory: URL, for metadata: TranscriptMetadata) -> URL {
        let name = fileName(for: metadata)
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        var url = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(counter).md")
            counter += 1
        }
        return url
    }

    static func sanitize(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = title.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
        let collapsed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(80)).trimmingCharacters(in: .whitespaces)
    }
}
