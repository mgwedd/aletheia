import AppKit
import Combine
import Foundation
import LocalAuthentication

/// Pure lock policy, so the launch/lock decision is unit-testable without the
/// LocalAuthentication framework.
enum AppLockPolicy {
    /// Whether the app should present the lock screen. Only lock when the user
    /// asked for it *and* the Mac can actually authenticate — otherwise a device
    /// with no Touch ID and no password would trap the user out of their data.
    static func shouldLock(enabled: Bool, canAuthenticate: Bool) -> Bool {
        enabled && canAuthenticate
    }

    /// HIPAA §164.312(a)(2)(iii) "automatic logoff": whether idle time alone
    /// should re-lock the app right now. Pure and time-injectable so it's
    /// testable without a running timer. `timeoutMinutes <= 0` ("Never")
    /// always answers false, regardless of how stale `lastActivity` is.
    static func shouldAutoLock(lastActivity: Date, timeoutMinutes: Int, now: Date) -> Bool {
        guard timeoutMinutes > 0 else { return false }
        let idleSeconds = now.timeIntervalSince(lastActivity)
        return idleSeconds >= TimeInterval(timeoutMinutes * 60)
    }
}

/// Tier-1 protection: gate opening the app behind Touch ID / the login password.
///
/// This is a *presentation* lock (it keeps the UI, and the PHI it shows, behind
/// the user's own authentication), not at-rest encryption — that's Tier 2. It's
/// deliberately frictionless: it changes no files and has no effect on backup or
/// restore. Combined with FileVault (which the setup screen recommends), it
/// covers the everyday "someone opened my unlocked Mac" exposure.
@MainActor
final class AppLock: ObservableObject {
    /// True while the lock screen should cover the app.
    @Published private(set) var isLocked: Bool
    /// Set when an unlock attempt fails, for the lock screen to show.
    @Published var lastError: String?

    /// Called once on each successful unlock, so the composition root can record
    /// an audit entry (HIPAA §164.312(b)) without `AppLock` depending on the log.
    var onUnlock: (() -> Void)?

    private let settings: AppSettings

    /// The last time the user interacted with the app (mouse/keyboard event
    /// delivered to one of its own windows), for the idle auto-lock clock.
    private var lastActivity = Date()
    /// Ticks periodically while idle auto-lock is armed; nil whenever it isn't
    /// (app lock off, or timeout is "Never") so there's nothing to invalidate.
    private var idleTimer: Timer?
    private var activityMonitor: Any?
    private var willSleepObserver: NSObjectProtocol?
    private var screensDidSleepObserver: NSObjectProtocol?
    private var screenLockObserver: NSObjectProtocol?
    private var settingsCancellable: AnyCancellable?

    /// How often the idle timer checks elapsed time against the configured
    /// timeout. Coarse on purpose: auto-lock only needs to notice idleness
    /// within a few seconds of the threshold, not to the millisecond, and the
    /// shortest offered timeout is a minute.
    private static let idleCheckInterval: TimeInterval = 10

    init(settings: AppSettings) {
        self.settings = settings
        self.isLocked = AppLockPolicy.shouldLock(
            enabled: settings.appLockEnabled,
            canAuthenticate: Self.canAuthenticate()
        )
        observeActivity()
        observeSystemSleep()
        // Re-evaluate whenever a relevant setting changes (app lock toggled,
        // or the idle timeout picked). `objectWillChange` fires before the
        // new value is actually stored, so hop to the next runloop turn to
        // read the settled value.
        settingsCancellable = settings.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.refreshIdleMonitoring() }
        }
        refreshIdleMonitoring()
    }

    deinit {
        idleTimer?.invalidate()
        settingsCancellable?.cancel()
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let willSleepObserver { workspaceCenter.removeObserver(willSleepObserver) }
        if let screensDidSleepObserver { workspaceCenter.removeObserver(screensDidSleepObserver) }
        if let screenLockObserver { DistributedNotificationCenter.default().removeObserver(screenLockObserver) }
    }

    /// Whether this Mac can evaluate Touch ID or the login password at all.
    static func canAuthenticate() -> Bool {
        var error: NSError?
        let ok = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        return ok
    }

    /// Re-lock now (e.g. when the app is hidden or sent to the background), so
    /// stepping away re-requires authentication. No-op when the lock is off.
    func lockIfEnabled() {
        if AppLockPolicy.shouldLock(enabled: settings.appLockEnabled, canAuthenticate: Self.canAuthenticate()) {
            isLocked = true
        }
    }

    /// Prompt for Touch ID / password and unlock on success. Password fallback
    /// is built into `.deviceOwnerAuthentication`, so there's always a way in.
    func unlock() async {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock Aletheia to view your patients' confidential notes."
            )
            if ok {
                isLocked = false
                lastError = nil
                onUnlock?()
                // Otherwise the next idle check would see a stale (very old)
                // `lastActivity` from before the app was locked and put the
                // lock screen right back up.
                lastActivity = Date()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Idle auto-lock (HIPAA §164.312(a)(2)(iii) "automatic logoff")

    /// Any mouse/keyboard event delivered to one of the app's own windows
    /// counts as activity and resets the idle clock.
    private func observeActivity() {
        activityMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel, .flagsChanged]
        ) { [weak self] event in
            Task { @MainActor in self?.recordActivity() }
            return event
        }
    }

    /// Record activity right now, resetting the idle clock. Called from the
    /// event monitor above; exposed so other activity signals could call it
    /// too if a need for one ever comes up.
    func recordActivity() {
        lastActivity = Date()
    }

    /// Sleep and screen-lock re-lock immediately rather than waiting for the
    /// idle timeout — a Mac going to sleep or a screen saver engaging is a
    /// much stronger "stepped away" signal than a timer.
    private func observeSystemSleep() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        willSleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.lockIfEnabled() }
        }
        screensDidSleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.lockIfEnabled() }
        }
        // Belt-and-suspenders: the screen saver / lock screen engaging
        // doesn't always coincide with the display or machine sleeping.
        screenLockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.lockIfEnabled() }
        }
    }

    /// Starts or stops the idle timer to match the current settings. Called
    /// on init and whenever settings change, so the timer only ever runs
    /// while it could actually do something.
    private func refreshIdleMonitoring() {
        guard settings.appLockEnabled, settings.idleAutoLockMinutes > 0 else {
            idleTimer?.invalidate()
            idleTimer = nil
            return
        }
        guard idleTimer == nil else { return }
        lastActivity = Date()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIdleTimeout() }
        }
    }

    private func checkIdleTimeout() {
        guard !isLocked else { return }
        if AppLockPolicy.shouldAutoLock(lastActivity: lastActivity, timeoutMinutes: settings.idleAutoLockMinutes, now: Date()) {
            lockIfEnabled()
        }
    }
}
