import Foundation

/// The wire format between the tab-listing AppleScript and the app: one tab
/// per record, URL and title separated by ASCII control characters that
/// cannot appear in either.
public enum BrowserTabList {
    public static let fieldSeparator = "\u{1F}"
    public static let recordSeparator = "\u{1E}"

    public static func parse(_ output: String) -> [BrowserTab] {
        output
            .trimmingCharacters(in: .newlines)
            .components(separatedBy: recordSeparator)
            .compactMap { record in
                let fields = record.components(separatedBy: fieldSeparator)
                guard fields.count == 2, !fields[0].isEmpty else { return nil }
                return BrowserTab(url: fields[0], title: fields[1])
            }
    }
}

public enum AppBundlePath {
    /// The outermost `.app` bundle in an executable's path.
    ///
    /// Browsers and Electron apps do their audio in helper processes nested
    /// deep inside the main bundle, and it is the main app that identifies
    /// the meeting.
    public static func outermostApp(in path: String) -> String? {
        let padded = path + "/"
        guard let range = padded.range(of: ".app/") else { return nil }
        return String(padded[..<range.lowerBound]) + ".app"
    }
}
