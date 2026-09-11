import Foundation
import os

/// Lists a browser's open tabs over AppleScript, to tell a Meet, Teams or Slack
/// call apart from anything else a browser might use the microphone for.
///
/// Runs `osascript` in a child process rather than `NSAppleScript`, which is
/// main-thread only and would block the UI for as long as the browser takes to
/// answer. Automation permission is still attributed to this app, so the first
/// call per browser shows the "Transcribe wants to control …" prompt.
public enum BrowserTabReader {
    private static let log = Logger(subsystem: "Transcribe", category: "BrowserTabs")

    /// The tabs open in the running app `bundleID`, or nil if they cannot be
    /// read: no scripting support, permission declined, or no answer in time.
    public static func tabs(bundleID: String, scripting: BrowserScripting) async -> [BrowserTab]? {
        let titleProperty: String
        switch scripting {
        case .chromium: titleProperty = "title"
        case .safari: titleProperty = "name"
        case .none: return nil
        }
        // The separators are `BrowserTabList`'s, made outside the `tell` block
        // so that no browser's dictionary can reinterpret `character`.
        let script = """
            set fieldSep to character id 31
            set recordSep to character id 30
            set out to ""
            tell application id "\(bundleID)"
                repeat with w in windows
                    try
                        set theURLs to URL of tabs of w
                        set theTitles to \(titleProperty) of tabs of w
                        repeat with i from 1 to count of theURLs
                            set out to out & (item i of theURLs as text) & fieldSep & (item i of theTitles as text) & recordSep
                        end repeat
                    end try
                end repeat
            end tell
            return out
            """
        guard let output = await runOSAScript(script, timeout: 5) else { return nil }
        return BrowserTabList.parse(output)
    }

    private static func runOSAScript(_ script: String, timeout: TimeInterval) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Drain output as it arrives: a browser with many tabs can produce more
        // than a pipe holds, and osascript would block writing it.
        let collected = OSAllocatedUnfairLock(initialState: Data())
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            collected.withLock { $0.append(data) }
        }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                let rest = stdout.fileHandleForReading.readDataToEndOfFile()
                let output = collected.withLock { String(decoding: $0 + rest, as: UTF8.self) }
                guard process.terminationStatus == 0 else {
                    let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    log.info("osascript failed: \(message, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: output)
            }
            do {
                try process.run()
            } catch {
                log.error("Could not run osascript: \(String(describing: error), privacy: .public)")
                process.terminationHandler = nil
                continuation.resume(returning: nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}
