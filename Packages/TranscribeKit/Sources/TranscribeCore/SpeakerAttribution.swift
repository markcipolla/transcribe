import Foundation

/// One reading of the call app, on the recording's timeline.
public struct CallSample: Sendable, Equatable {
    /// Seconds from the start of the recording, with the app's own lag in
    /// marking the talker already taken off.
    public var time: TimeInterval
    public var reading: CallReading

    public init(time: TimeInterval, reading: CallReading) {
        self.time = time
        self.reading = reading
    }
}

/// Who said a line of the meeting audio, from what the call app showed while
/// it was said. Never a guess: a name only when the app marked one other
/// person as talking for most of the line, or the call has one other person.
public enum SpeakerAttribution {
    /// A reading stands until the next, but never longer than this, so an app
    /// that stops answering never keeps naming someone.
    public static let hold: TimeInterval = 2
    /// The apps mark the talker about this late (Zoom: 0.75 to 1.2 s).
    public static let appLag: TimeInterval = 0.75

    static func norm(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    static func isMe(_ name: String, _ r: CallReading, _ myNames: [String]) -> Bool {
        let n = norm(name)
        return r.me.map(norm) == n || myNames.contains { !$0.isEmpty && norm($0) == n }
    }

    /// The other side at one reading, or nil when it can't be told.
    public static func who(at r: CallReading, myNames: [String]) -> String? {
        guard r.windowFound else { return nil }
        let people = CallParser.unique(r.participants)
        if people.count == 2 {
            let mine = people.filter { isMe($0, r, myNames) }
            if mine.count == 1 { return people.first { !isMe($0, r, myNames) } }
        }
        let others = CallParser.unique(r.speaking.filter { !isMe($0, r, myNames) })
        return others.count == 1 ? others[0] : nil
    }

    /// The name for meeting audio spoken over `start...end`, or nil for Others.
    /// `samples` must be in time order.
    public static func name(start: TimeInterval, end: TimeInterval, samples: [CallSample], myNames: [String]) -> String? {
        guard !samples.isEmpty else { return nil }
        func span(_ i: Int) -> (TimeInterval, TimeInterval) {
            let next = i + 1 < samples.count ? samples[i + 1].time : .infinity
            return (samples[i].time, min(next, samples[i].time + hold))
        }
        // The first reading after `start`: the one before it may still stand.
        var lo = 0, hi = samples.count
        while lo < hi { let mid = (lo + hi) / 2; if samples[mid].time <= start { lo = mid + 1 } else { hi = mid } }
        if end <= start {
            guard lo > 0 else { return nil }
            return start < span(lo - 1).1 ? who(at: samples[lo - 1].reading, myNames: myNames) : nil
        }
        var time: [String: TimeInterval] = [:]
        for i in max(0, lo - 1)..<samples.count {
            let (a, b) = span(i)
            if a >= end { break }
            let overlap = min(b, end) - max(a, start)
            guard overlap > 0, let name = who(at: samples[i].reading, myNames: myNames) else { continue }
            time[name, default: 0] += overlap
        }
        guard let best = time.max(by: { $0.value < $1.value }), best.value > 0.5 * (end - start) else { return nil }
        return best.key
    }
}

/// Whether reading the call app worked in a finished recording. When the app
/// has changed under us, the recording offers to report it.
public enum SpeakerNamingHealth {
    /// Readings needed before judging: about 15 seconds of the call window.
    static let minimumReadings = 30
    /// Words of meeting audio needed: a call where the others barely spoke
    /// says nothing about whether talkers are marked.
    static let minimumWords = 40

    /// Why naming looks broken, or nil when it worked or can't be told.
    public static func problem(samples: [CallSample], systemWords: Int) -> String? {
        let seen = samples.filter(\.reading.windowFound)
        guard seen.count >= minimumReadings, systemWords >= minimumWords else { return nil }
        guard seen.contains(where: { !$0.reading.participants.isEmpty }) else {
            return "No participants were found in the call window."
        }
        // Zoom only marks talkers with three or more in the call; the others
        // may well do the same, so a call of two proves nothing.
        let most = seen.map { CallParser.unique($0.reading.participants).count }.max() ?? 0
        if most >= 3, !seen.contains(where: { !$0.reading.speaking.isEmpty }) {
            return "\(most) participants were found, but nobody was ever marked as talking."
        }
        return nil
    }
}

/// The GitHub issue a recording offers to file when naming broke. One open
/// issue per app: its title is how the app tells whether one is already open.
public struct SpeakerNamingReport: Sendable {
    public static let repository = "markcipolla/transcribe"

    public var platform: MeetingPlatform
    /// The app the call was in: "Google Chrome 142.0", "Slack 4.47".
    public var app: String
    public var transcribeVersion: String
    public var macOSVersion: String
    public var problem: String
    /// The masked tree of one reading from the middle of the call.
    public var windows: [AXWindow]

    public init(platform: MeetingPlatform, app: String, transcribeVersion: String,
                macOSVersion: String, problem: String, windows: [AXWindow]) {
        self.platform = platform
        self.app = app
        self.transcribeVersion = transcribeVersion
        self.macOSVersion = macOSVersion
        self.problem = problem
        self.windows = AXDump.masked(windows)
    }

    public static func title(for platform: MeetingPlatform) -> String {
        "Speaker names stopped working in \(platform.rawValue)"
    }

    public var title: String { Self.title(for: platform) }

    /// Issue URLs much past 8 KB are refused, so the outline is cut to fit and
    /// the whole dump is attached by hand.
    public func body(maxOutline: Int = 4500) -> String {
        var outline = AXDump.outline(windows)
        if outline.count > maxOutline { outline = String(outline.prefix(maxOutline)) + "\n… (cut; the full dump is attached)" }
        return """
        Transcribe couldn't tell who was talking in a \(platform.rawValue) call.

        **What went wrong:** \(problem)

        - Transcribe \(transcribeVersion)
        - \(app)
        - macOS \(macOSVersion)

        Names and other text in the dump below are masked (letters → 🔳, digits → 🔲). \
        Please drag the full dump file Transcribe showed you in Finder into this issue.

        <details><summary>Call window, outlined</summary>

        ```
        \(outline)
        ```

        </details>
        """
    }

    /// GitHub's new-issue page with the title and body filled in. The person
    /// reviews it and submits it from their own account: the app holds no token.
    /// The outline shrinks until the URL fits, since encoding can triple it.
    public var newIssueURL: URL {
        var c = URLComponents(string: "https://github.com/\(Self.repository)/issues/new")!
        var outline = 4500
        repeat {
            c.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body(maxOutline: outline))]
            outline -= 500
        } while c.url!.absoluteString.count > 7500 && outline > 0
        return c.url!
    }

    /// Search for an open issue with this title. A closed one means the last
    /// break was fixed, so a new break files a new issue.
    public static func openIssueSearchURL(for platform: MeetingPlatform) -> URL {
        var c = URLComponents(string: "https://api.github.com/search/issues")!
        c.queryItems = [URLQueryItem(
            name: "q", value: "repo:\(repository) is:issue is:open in:title \"\(title(for: platform))\"")]
        return c.url!
    }

    /// The full masked dump, to attach to the issue.
    public func dumpJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(windows)
    }
}
