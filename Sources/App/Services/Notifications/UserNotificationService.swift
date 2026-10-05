import UserNotifications

/// UserNotifications-backed implementation. Authorization is requested lazily
/// and in context (right before a transcription starts), per Apple's
/// guidance, rather than nagging on launch.
final class UserNotificationService: AppNotifying {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func post(_ content: AppNotificationContent) async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        notification.sound = .default
        // nil trigger delivers immediately.
        let request = UNNotificationRequest(identifier: content.identifier, content: notification, trigger: nil)
        try? await center.add(request)
    }
}
