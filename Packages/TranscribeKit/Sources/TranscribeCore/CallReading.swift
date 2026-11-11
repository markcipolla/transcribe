import Foundation

// Who is in a call and who is talking, read from the call app's accessibility
// tree. The idea and Meet's measurements come from Yogurt (MIT,
// github.com/FrigadeHQ/yogurt). Every rule fails towards reading nothing, so a
// changed app means "Others", never a wrong name. When an app changes, a
// recording notices (SpeakerNamingHealth) and offers to file an issue with a
// masked dump of the tree, and the fix is usually one constant in this file.

/// One element of an accessibility tree, as copied out of the call app.
public struct AXNode: Sendable, Equatable, Codable {
    public var role: String
    public var subrole: String?
    /// AXDescription: where Zoom, Teams and Slack put labels like "Ann, muted".
    public var label: String?
    public var title: String?
    public var value: String?
    public var identifier: String?
    /// AXDOMClassList: the DOM classes of a web element (Chromium and Electron).
    public var classes: [String]?
    public var children: [AXNode]?

    public init(role: String, subrole: String? = nil, label: String? = nil, title: String? = nil,
                value: String? = nil, identifier: String? = nil, classes: [String]? = nil,
                children: [AXNode]? = nil) {
        self.role = role
        self.subrole = subrole
        self.label = label
        self.title = title
        self.value = value
        self.identifier = identifier
        self.classes = classes
        self.children = children
    }

    var texts: [String] { [label, title, value].compactMap { $0 }.filter { !$0.isEmpty } }

    /// Visit every node with its ancestors, nearest last.
    func walk(_ visit: (AXNode, [AXNode]) -> Void) {
        func go(_ node: AXNode, _ up: [AXNode]) {
            visit(node, up)
            for child in node.children ?? [] { go(child, up + [node]) }
        }
        go(self, [])
    }
}

public struct AXWindow: Sendable, Equatable, Codable {
    public var title: String?
    public var tree: AXNode

    public init(title: String?, tree: AXNode) {
        self.title = title
        self.tree = tree
    }
}

/// What the call app showed at one moment.
public struct CallReading: Sendable, Equatable {
    /// Who the app marks as talking.
    public var speaking: [String]
    /// Everyone the app shows in the call, you included.
    public var participants: [String]
    /// Which participant is you, when the app says ("You", "(me)").
    public var me: String?
    /// Whether a window for the call was there to read at all. A Meet tab in
    /// the background, say, is not: that says nothing about whether Meet changed.
    public var windowFound: Bool

    public init(speaking: [String] = [], participants: [String] = [], me: String? = nil, windowFound: Bool) {
        self.speaking = speaking
        self.participants = participants
        self.me = me
        self.windowFound = windowFound
    }
}

public enum CallParser {
    /// - Parameter inBrowser: the windows are a browser's, so only those
    ///   titled for the call app are read; a desktop app's are all its own.
    public static func read(_ platform: MeetingPlatform, windows: [AXWindow], inBrowser: Bool = false) -> CallReading {
        switch platform {
        case .googleMeet: return readMeet(windows)
        case .teams: return readLabelled(windows, titleHint: inBrowser ? "Teams" : nil)
        case .slack: return readLabelled(windows, titleHint: inBrowser ? "Slack" : nil)
        case .browserCall, .manual: return CallReading(windowFound: false)
        }
    }

    // MARK: Google Meet

    /// The class Meet puts on the tile of whoever is talking. It is a build
    /// name Google changes between releases, so when nobody is ever marked in a
    /// call of three or more, a recording offers to report it. Measured
    /// October 2026 (via Yogurt). Several can be listed while one rolls out.
    public static let meetTalkingClasses: Set<String> = ["v5h6Xc"]
    /// A Meet tile is the element this many levels above a name's text,
    /// holding just that one name.
    public static let meetTileDepth = 7

    static func readMeet(_ windows: [AXWindow]) -> CallReading {
        // Only a Meet window: Chrome's other windows are someone's email.
        let meet = windows.filter { $0.title?.contains("Meet") ?? false }
        guard !meet.isEmpty else { return CallReading(windowFound: false) }
        var tiles: [(node: AXNode, names: [String])] = []
        for window in meet {
            // The meeting's own name is on screen too, and is nobody.
            let skip = Set((window.title ?? "").components(separatedBy: CharacterSet(charactersIn: "-–—"))
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            // Nodes are values, so a tile is told apart by its path from the root.
            var tileAt: [[Int]: Int] = [:]
            window.tree.walkWithPath { node, up, path in
                guard node.role == "AXStaticText", let text = node.value, up.count >= meetTileDepth,
                      let name = meetName(text), !skip.contains(name.lowercased()) else { return }
                let root = Array(path.dropLast(meetTileDepth))
                if let i = tileAt[root] {
                    tiles[i].names.append(name)
                } else {
                    tileAt[root] = tiles.count
                    tiles.append((up[up.count - meetTileDepth], [name]))
                }
            }
        }
        var reading = CallReading(windowFound: true)
        for tile in tiles {
            let names = unique(tile.names)
            guard names.count == 1, let name = names.first else { continue }
            reading.participants.append(name)
            if name.lowercased() == "you" { reading.me = name }
            var talking = false
            tile.node.walk { node, _ in
                if node.classes?.contains(where: meetTalkingClasses.contains) ?? false { talking = true }
            }
            if talking { reading.speaking.append(name) }
        }
        reading.participants = unique(reading.participants)
        reading.speaking = unique(reading.speaking)
        return reading
    }

    static func meetName(_ text: String) -> String? {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let paren = name.range(of: #"\s*\((presenting|presentation|you)[^)]*\)\s*$"#,
                                  options: [.regularExpression, .caseInsensitive]) {
            name.removeSubrange(paren)
        }
        guard (2...60).contains(name.count), name.contains(where: \.isLetter),
              name.range(of: #"^\d{1,2}[:.]\d{2}(\s?[AP]M)?$|^[a-z]{3}-[a-z]{4}-[a-z]{3}$|says in chat|^(AM|PM)$"#,
                         options: [.regularExpression, .caseInsensitive]) == nil
        else { return nil }
        return name
    }

    // MARK: Teams and Slack

    // Not yet measured on a real call. These read words, which change less
    // often than layout: labels like "Ann Lee, speaking" or "Ann Lee, muted",
    // "(You)" after your own name, and a DOM class with "speaking" or
    // "talking" in it around a single name (Slack's classes are readable, like
    // c-huddle_avatar--speaking). Slack's accessibility changelog says huddle
    // members' labels carry their microphone and camera status. The first real
    // call either works or files the issue that says how it should read.
    static let speakingLabels = [
        #"^(.{2,60}?)(?:,\s*|\s+is\s+)(?:speaking|talking)\b"#,
        #"\b(?:active speaker|now speaking|speaking now)[:,]?\s+(.{2,60})$"#,
    ]
    static let tileLabel = #"^(.{2,60}?),\s*(?:muted|unmuted|mic(?:rophone)?(?: is)? (?:on|off)|video (?:is )?(?:on|off)|camera (?:is )?(?:on|off))\b"#
    static let meLabel = #"^(.{2,60}?)\s*\((?:you|me)\)"#
    static let speakingClass = #"(?:^|[-_])(?:is[-_]?)?(?:speaking|talking|active[-_]?speaker)(?:$|[-_])"#

    static func readLabelled(_ windows: [AXWindow], titleHint: String?) -> CallReading {
        // A browser's other windows are not the call.
        let call = titleHint.map { hint in windows.filter { $0.title?.contains(hint) ?? false } } ?? windows
        guard !call.isEmpty else { return CallReading(windowFound: false) }
        var reading = CallReading(windowFound: true)
        for window in call {
            window.tree.walk { node, _ in
                for text in node.texts {
                    for pattern in speakingLabels {
                        if let name = capture(pattern, in: text).map(cleanLabelled),
                           name.count >= 2, name.lowercased() != "you" {
                            reading.speaking.append(name)
                        }
                    }
                    if let name = capture(tileLabel, in: text).map(cleanLabelled) { reading.participants.append(name) }
                    if let name = capture(meLabel, in: text).map(cleanLabelled) {
                        reading.me = name
                        reading.participants.append(name)
                    }
                }
                if node.classes?.contains(where: { $0.range(of: speakingClass, options: [.regularExpression, .caseInsensitive]) != nil }) ?? false {
                    var names: [String] = []
                    node.walk { inner, _ in
                        if inner.role == "AXStaticText", let v = inner.value, let n = meetName(v) { names.append(n) }
                    }
                    if unique(names).count == 1 { reading.speaking.append(names[0]) }
                }
            }
        }
        reading.participants = unique(reading.participants.filter { $0.count >= 2 })
        reading.speaking = unique(reading.speaking)
        return reading
    }

    static func cleanLabelled(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*\((?:organizer|presenter|guest|external|host|you|me)\)"#,
                               with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.:; "))
    }

    static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }
}

extension AXNode {
    /// `walk`, plus each node's child-index path from the root.
    func walkWithPath(_ visit: (AXNode, [AXNode], [Int]) -> Void) {
        func go(_ node: AXNode, _ up: [AXNode], _ path: [Int]) {
            visit(node, up, path)
            for (i, child) in (node.children ?? []).enumerated() { go(child, up + [node], path + [i]) }
        }
        go(self, [], [])
    }
}

/// A call window's tree with the people taken out, for a public issue.
///
/// Letters become `a`/`A` and digits `0`, so "Ann Lee, muted" reads
/// "Aaa Aaa, muted": the shape of a label survives, the name does not. Words
/// the call apps use for their own UI stay, so a renamed label can be seen.
/// DOM classes and identifiers are the app's code, not anyone's data, and stay.
public enum AXDump {
    static let uiWords: Set<String> = [
        "you", "me", "is", "are", "speaking", "talking", "active", "speaker", "now", "muted", "unmuted",
        "mute", "unmute", "microphone", "mic", "camera", "video", "audio", "on", "off", "computer",
        "presenting", "presentation", "host", "organizer", "presenter", "guest", "external", "participants",
        "participant", "people", "members", "member", "huddle", "call", "meeting", "raise", "raised", "hand",
        "leave", "join", "joined", "share", "screen", "chat", "more", "options", "pin", "pinned", "and",
        "others", "other", "list", "button", "tile", "avatar", "meet", "teams", "slack", "google",
    ]

    public static func mask(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let bare = word.lowercased().filter(\.isLetter)
            if uiWords.contains(bare) { return String(word) }
            return String(word.map { c -> Character in
                if c.isLetter { return c.isUppercase ? "A" : "a" }
                if c.isNumber { return "0" }
                return c
            })
        }.joined(separator: " ")
    }

    public static func masked(_ node: AXNode) -> AXNode {
        var node = node
        node.label = node.label.map(mask)
        node.title = node.title.map(mask)
        node.value = node.value.map(mask)
        node.children = node.children?.map(masked)
        return node
    }

    public static func masked(_ windows: [AXWindow]) -> [AXWindow] {
        windows.map { AXWindow(title: $0.title.map(mask), tree: masked($0.tree)) }
    }

    /// Indented lines, one per element that says something, short enough for
    /// an issue body: `role "label" .class.class`.
    public static func outline(_ windows: [AXWindow], maxLines: Int = 120) -> String {
        var lines: [String] = []
        var roles: [String: Int] = [:]
        for window in windows {
            lines.append("window \"\(window.title ?? "")\"")
            window.tree.walk { node, up in
                roles[node.role, default: 0] += 1
                let said = node.texts.map { "\"\($0.prefix(80))\"" }
                let classes = node.classes.map { $0.isEmpty ? "" : " ." + $0.prefix(6).joined(separator: ".") } ?? ""
                guard !said.isEmpty || !classes.isEmpty, lines.count < maxLines else { return }
                lines.append(String(repeating: "  ", count: min(up.count, 16)) + node.role
                             + (said.isEmpty ? "" : " " + said.joined(separator: " ")) + classes)
            }
        }
        let counts = roles.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return (["roles: " + counts] + lines).joined(separator: "\n")
    }
}
