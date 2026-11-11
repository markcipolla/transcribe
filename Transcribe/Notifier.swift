import AppKit
import UserNotifications

/// Posts "started" and "saved" notifications. Clicking a "saved" one opens
/// the transcript.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private static let fileKey = "file"
    private static let urlKey = "url"
    private static let revealKey = "reveal"

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// - Parameters:
    ///   - fileURL: opened on click.
    ///   - link: a web page opened on click, with `reveal` shown in Finder.
    func post(title: String, body: String, fileURL: URL? = nil, link: URL? = nil, reveal: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        var info: [String: String] = [:]
        info[Self.fileKey] = fileURL?.path
        info[Self.urlKey] = link?.absoluteString
        info[Self.revealKey] = reveal?.path
        content.userInfo = info
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let file = info[Self.fileKey] as? String, link = info[Self.urlKey] as? String
        let reveal = info[Self.revealKey] as? String
        await MainActor.run {
            if let file { NSWorkspace.shared.open(URL(fileURLWithPath: file)) }
            if let link = link.flatMap(URL.init(string:)) { NSWorkspace.shared.open(link) }
            if let reveal { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: reveal)]) }
        }
    }

    /// Show notifications even though a menu bar app is always "in front".
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
