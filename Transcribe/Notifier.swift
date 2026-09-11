import AppKit
import UserNotifications

/// Posts "started" and "saved" notifications. Clicking a "saved" one opens
/// the transcript.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private static let fileKey = "file"

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, fileURL: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let fileURL { content.userInfo = [Self.fileKey: fileURL.path] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo[Self.fileKey] as? String else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }

    /// Show notifications even though a menu bar app is always "in front".
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
