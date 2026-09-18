import Combine
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Keeps a status view (the setup checklist, the Settings status section) in
/// step with the world without the user hitting a "Refresh" button:
///
///  - runs once when the view appears,
///  - runs again every time the app is brought back to the front — which is the
///    moment the therapist returns from granting a permission in System
///    Settings or from launching Ollama, and
///  - runs on a slow background tick while the view is on screen, so a change
///    that happened in place still lands within a couple of seconds.
///
/// The action gets an `authoritative` flag: true for the appear/activation runs
/// (the caller can afford the reliable, possibly-prompting checks then), false
/// for the background tick (stay on cheap, never-prompting probes).
struct LiveStatusRefresh: ViewModifier {
    let action: (_ authoritative: Bool) async -> Void
    // Held as one publisher rather than created inline in `.onReceive`, which
    // would rebuild (and effectively reset) the timer on every re-render.
    private let timer: Publishers.Autoconnect<Timer.TimerPublisher>

    init(interval: TimeInterval, action: @escaping (_ authoritative: Bool) async -> Void) {
        self.action = action
        self.timer = Timer.publish(every: interval, on: .main, in: .common).autoconnect()
    }

    func body(content: Content) -> some View {
        content
            .task { await action(true) }
            .onReceive(timer) { _ in
                Task { await action(false) }
            }
            #if canImport(AppKit)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await action(true) }
            }
            #endif
    }
}

extension View {
    /// Auto-refreshes a status view on appear, on app re-activation, and on a
    /// slow timer. See `LiveStatusRefresh`.
    func liveStatusRefresh(every interval: TimeInterval = 2.5, action: @escaping (_ authoritative: Bool) async -> Void) -> some View {
        modifier(LiveStatusRefresh(interval: interval, action: action))
    }
}
