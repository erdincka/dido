import AppKit
import UserNotifications
import os

/// Posts a system notification when a scan finishes while Dido is in the background.
@MainActor
final class LibraryNotifier {
    static let shared = LibraryNotifier()

    private var authorised: Bool?
    private let logger = Logger(subsystem: "com.dido", category: "Notifier")

    private init() {}

    func notify(title: String, body: String) async {
        guard !NSApp.isActive else { return }
        if authorised == nil {
            do {
                authorised = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            } catch {
                authorised = false
                logger.info("Notifications unavailable: \(error.localizedDescription)")
            }
        }
        guard authorised == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "dido.index.\(UUID().uuidString)", content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logger.info("Notification failed: \(error.localizedDescription)")
        }
    }
}
