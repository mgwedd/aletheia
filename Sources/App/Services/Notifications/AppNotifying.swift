import Foundation

/// One user-facing notification the app wants to deliver.
struct AppNotificationContent: Equatable {
    let identifier: String
    let title: String
    let body: String
}

/// The system-notification integration, behind a protocol so the app's
/// completion flows don't depend on UserNotifications directly (and so it's
/// testable with a fake). Delivering a banner when a long-running task
/// finishes is the whole point — the therapist can step away during a
/// multi-minute transcription and be told when it's ready.
protocol AppNotifying {
    /// Ask the user (once) to allow notifications. Safe to call repeatedly.
    func requestAuthorization() async

    /// Deliver a notification now.
    func post(_ content: AppNotificationContent) async
}
