import AppKit
import ApplicationServices
import Foundation
import os

/// Reads the call app's windows over Accessibility twice a second during a
/// recording, for who is in the call and who is talking (CallParser).
///
/// Needs the Accessibility permission. Without it, or for a call it can't
/// read, it collects nothing and the meeting audio stays Others.
public final class CallWatcher: @unchecked Sendable {
    public static let interval: Duration = .milliseconds(500)
    /// Elements copied per reading, so a huge page can't stall the loop.
    static let nodeBudget = 8000
    static let maxDepth = 60

    public let platform: MeetingPlatform
    private let bundleID: String
    private let startedAt: Date
    private let lock = NSLock()
    private var _samples: [CallSample] = []
    private var _dump: [AXWindow] = []
    private var found = 0
    private var task: Task<Void, Never>?
    private static let log = Logger(subsystem: "Transcribe", category: "CallWatcher")

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Show the system prompt that sends you to Accessibility in Settings.
    public static func requestTrust() {
        // kAXTrustedCheckOptionPrompt, which Swift 6 won't read from a global var.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Nil for a call whose app has no reader.
    public init?(meeting: DetectedMeeting, startedAt: Date) {
        guard [.googleMeet, .teams, .slack].contains(meeting.platform) else { return nil }
        platform = meeting.platform
        // A Chrome or Edge web app's windows belong to the browser itself, not
        // to the app shim whose bundle ID detection saw.
        bundleID = MeetingClassifier.isSiteApp(meeting.appBundleID)
            ? String(meeting.appBundleID.prefix(upTo: meeting.appBundleID.range(of: ".app.")!.lowerBound))
            : meeting.appBundleID
        self.startedAt = startedAt
    }

    /// Readings so far, in time order.
    public var samples: [CallSample] { lock.withLock { _samples } }

    /// The tree from a reading that found the call window, for a report.
    /// Kept from the middle of the call rather than the end, when people leave.
    public var dump: [AXWindow] { lock.withLock { _dump } }

    /// "Google Chrome 142.0.7444.60"
    public var appDescription: String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let url = app.bundleURL, let bundle = Bundle(url: url) else { return bundleID }
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "\(app.localizedName ?? bundleID) \(version)"
    }

    public func start() {
        guard Self.isTrusted else {
            Self.log.info("No Accessibility permission; speakers stay unnamed")
            return
        }
        let inBrowser = MeetingClassifier.kind(ofApp: bundleID).map { if case .browser = $0 { true } else { false } } ?? false
        task = Task.detached(priority: .utility) { [weak self] in
            var askedForTree = false
            while !Task.isCancelled, let self {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: self.bundleID).first {
                    let element = AXUIElementCreateApplication(app.processIdentifier)
                    AXUIElementSetMessagingTimeout(element, 0.25)
                    if !askedForTree {
                        // Chromium and Electron only build their tree for an
                        // assistive app that asks, as screen readers do.
                        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                        askedForTree = true
                    }
                    let windows = Self.windows(of: element)
                    let reading = CallParser.read(self.platform, windows: windows, inBrowser: inBrowser)
                    self.record(reading, windows: windows)
                }
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func record(_ reading: CallReading, windows: [AXWindow]) {
        let time = Date().timeIntervalSince(startedAt) - SpeakerAttribution.appLag
        lock.withLock {
            _samples.append(CallSample(time: time, reading: reading))
            // Every 20th reading for the first five minutes: a picture from
            // well into the call, before people start leaving.
            guard reading.windowFound else { return }
            if found % 20 == 0, found <= 600 { _dump = windows }
            found += 1
        }
    }

    // MARK: - Accessibility

    private static let keys = [kAXRoleAttribute, kAXSubroleAttribute, kAXDescriptionAttribute, kAXTitleAttribute,
                               kAXValueAttribute, kAXIdentifierAttribute, "AXDOMClassList", kAXChildrenAttribute]

    static func windows(of app: AXUIElement) -> [AXWindow] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        var budget = nodeBudget
        return windows.map { window in
            var title: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            return AXWindow(title: title as? String, tree: copy(window, depth: 0, budget: &budget))
        }
    }

    static func copy(_ element: AXUIElement, depth: Int, budget: inout Int) -> AXNode {
        budget -= 1
        var raw: CFArray?
        AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, AXCopyMultipleAttributeOptions(), &raw)
        let values = (raw as? [AnyObject]) ?? []
        // Missing attributes come back as AXValue errors, not strings.
        func text(_ i: Int) -> String? {
            guard i < values.count, let s = values[i] as? String, !s.isEmpty else { return nil }
            return s
        }
        var node = AXNode(role: text(0) ?? "?", subrole: text(1), label: text(2), title: text(3),
                          value: text(4), identifier: text(5),
                          classes: values.count > 6 ? (values[6] as? [String]).flatMap { $0.isEmpty ? nil : $0 } : nil)
        if depth < maxDepth, values.count > 7, let children = values[7] as? [AXUIElement], !children.isEmpty {
            var kids: [AXNode] = []
            for child in children {
                guard budget > 0 else { break }
                kids.append(copy(child, depth: depth + 1, budget: &budget))
            }
            node.children = kids
        }
        return node
    }
}
