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

extension AppLockPolicy {
    /// Whether to show the system Touch ID sheet right now. Only while the app
    /// is frontmost: a lock that happened in the background (idle, sleep) waits
    /// until the user comes back, instead of popping a prompt over another app.
    static func shouldPromptNow(isLocked: Bool, appIsActive: Bool) -> Bool {
        isLocked && appIsActive
    }
}

/// What re-locks the app once it has been unlocked: the Mac itself being left.
/// One unlock lasts the user's session on this Mac. Hiding Aletheia (⌘H),
/// switching apps and the display dimming or sleeping on its own do not
/// re-lock; the idle timer is a separate, opt-in setting.
enum RelockTrigger: CaseIterable, Equatable {
    case systemSleep
    case screenLock
    case userSwitch

    var notificationName: Notification.Name {
        switch self {
        case .systemSleep: return NSWorkspace.willSleepNotification
        case .screenLock: return Notification.Name("com.apple.screenIsLocked")
        case .userSwitch: return NSWorkspace.sessionDidResignActiveNotification
        }
    }

    /// The screen lock is only announced on the distributed center; the
    /// others come from `NSWorkspace.shared.notificationCenter`.
    var isDistributed: Bool { self == .screenLock }
}

/// After the user cancels the system sheet, don't auto-prompt again until the app
/// has really been left and come back: the sheet's own activation changes would
/// otherwise re-prompt in a loop. The lock button is never gated.
struct AutoPromptGate: Equatable {
    private var cancelled = false
    private var resignedSinceCancel = false

    var allowsAutoPrompt: Bool { !cancelled || resignedSinceCancel }

    mutating func userCancelled() { cancelled = true; resignedSinceCancel = false }
    mutating func appResigned() { if cancelled { resignedSinceCancel = true } }
    mutating func reset() { cancelled = false; resignedSinceCancel = false }
}

/// Admits one operation at a time: `begin()` returns true only if nothing is
/// running, until `end()`. Used so two triggers for the same unlock prompt
/// (launch, becoming active, a click) don't stack a second system dialog or
/// record a second audit entry.
struct SingleFlight: Equatable {
    private(set) var isRunning = false

    mutating func begin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    mutating func end() {
        isRunning = false
    }
}

/// The only words the lock flow uses. The lock screen itself is just a lock
/// symbol; the system sheet carries the reason.
enum LockScreenCopy {
    /// Accessibility label and tooltip of the lock symbol button.
    static let unlockLabel = "Unlock"
    /// Passed to `evaluatePolicy`. macOS renders the sheet as
    /// "<App> is trying to <reason>." (it adds the prefix and the final period),
    /// so this is lowercase-initial, does not name the app, and has no period.
    static let authenticationReason = "unlock your patient notes"
}

/// Shows the system Touch ID / password sheet. A seam so the unlock flow is
/// testable without a real sheet.
protocol UnlockAuthenticator {
    /// Returns true when the user authenticated; throws on cancel or failure.
    func authenticate(reason: String) async throws -> Bool
}

struct SystemUnlockAuthenticator: UnlockAuthenticator {
    func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }
}

/// Used while the app is hosting unit tests: it never shows the system sheet,
/// so lock tests don't put Touch ID prompts on the developer's screen. It
/// answers as if the sheet was cancelled, so it can never unlock the app.
struct NonPromptingUnlockAuthenticator: UnlockAuthenticator {
    func authenticate(reason: String) async throws -> Bool {
        throw LAError(.appCancel)
    }
}

enum UnlockAuthenticatorFactory {
    /// The system sheet, except when XCTest is driving this process.
    static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UnlockAuthenticator {
        if environment["XCTestConfigurationFilePath"] != nil {
            return NonPromptingUnlockAuthenticator()
        }
        return SystemUnlockAuthenticator()
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
    /// Called when an unlock attempt fails (not user cancellation), to record
    /// failed authentication attempts in the audit log (HIPAA §164.312(b)).
    var onUnlockFailed: ((String) -> Void)?

    private let settings: AppSettings
    private let canAuthenticateProvider: () -> Bool
    private let authenticator: UnlockAuthenticator
    private let isAppActive: () -> Bool
    private var unlockFlight = SingleFlight()

    /// The last time the user interacted with the app (mouse/keyboard event
    /// delivered to one of its own windows), for the idle auto-lock clock.
    private var lastActivity = Date()
    /// Ticks periodically while idle auto-lock is armed; nil whenever it isn't
    /// (app lock off, or timeout is "Never") so there's nothing to invalidate.
    private var idleTimer: Timer?
    private var activityMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var didResignActiveObserver: NSObjectProtocol?
    private var promptGate = AutoPromptGate()
    private var settingsCancellable: AnyCancellable?

    /// How often the idle timer checks elapsed time against the configured
    /// timeout. Coarse on purpose: auto-lock only needs to notice idleness
    /// within a few seconds of the threshold, not to the millisecond, and the
    /// shortest offered timeout is a minute.
    private static let idleCheckInterval: TimeInterval = 10

    init(
        settings: AppSettings,
        canAuthenticate: @escaping () -> Bool = AppLock.canAuthenticate,
        authenticator: UnlockAuthenticator = UnlockAuthenticatorFactory.make(),
        isAppActive: @escaping () -> Bool = { NSApp.isActive }
    ) {
        self.settings = settings
        self.authenticator = authenticator
        self.isAppActive = isAppActive
        self.canAuthenticateProvider = canAuthenticate
        self.isLocked = AppLockPolicy.shouldLock(
            enabled: settings.appLockEnabled,
            canAuthenticate: canAuthenticate()
        )
        // A lock that happened (or a launch) while another app was frontmost
        // prompts once the user comes back.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.unlockIfActive() }
        }
        didResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.promptGate.appResigned() }
        }
        observeActivity()
        observeRelockTriggers()
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
        if let didBecomeActiveObserver { NotificationCenter.default.removeObserver(didBecomeActiveObserver) }
        if let didResignActiveObserver { NotificationCenter.default.removeObserver(didResignActiveObserver) }
        settingsCancellable?.cancel()
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    /// Whether this Mac can evaluate Touch ID or the login password at all.
    /// Touches no `AppLock` state, so it is callable from any thread and can be
    /// the plain `() -> Bool` default for `init`'s `canAuthenticate`.
    nonisolated static func canAuthenticate() -> Bool {
        var error: NSError?
        let ok = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        return ok
    }

    /// Re-lock now (e.g. when the Mac sleeps or locks), so
    /// stepping away re-requires authentication. No-op when the lock is off.
    func lockIfEnabled() {
        if AppLockPolicy.shouldLock(enabled: settings.appLockEnabled, canAuthenticate: canAuthenticateProvider()) {
            isLocked = true
            SessionSearch.setAppLocked(true)
            // SQLite's page cache holds indexed text; don't keep it open behind the lock screen.
            SessionSearch.closeIndex()
            LlamaRuntime.unloadAll()   // the built-in model's KV cache holds the last transcript
        }
    }

    /// Test seam: puts the lock into the unlocked state without prompting Touch ID.
    func simulateUnlockedForTesting() {
        isLocked = false
        SessionSearch.setAppLocked(false)
    }

    /// Test seam: simulate a failed unlock attempt with a specific error message.
    func simulateUnlockFailedForTesting(reason: String = "Authentication failed") {
        lastError = reason
        onUnlockFailed?(reason)
    }

    /// The automatic prompt: only when locked and the app is frontmost.
    func unlockIfActive() async {
        guard AppLockPolicy.shouldPromptNow(isLocked: isLocked, appIsActive: isAppActive()),
              promptGate.allowsAutoPrompt else { return }
        promptGate.reset()
        await unlock()
    }

    /// Fire-and-forget unlock for the lock button. Overlapping calls are
    /// coalesced by the single-flight guard in `unlock()`.
    func requestUnlock() {
        Task { await unlock() }
    }

    /// Prompt for Touch ID / password and unlock on success. Password fallback
    /// is built into `.deviceOwnerAuthentication`, so there's always a way in.
    func unlock() async {
        guard unlockFlight.begin() else { return }
        defer { unlockFlight.end() }
        do {
            let ok = try await authenticator.authenticate(reason: LockScreenCopy.authenticationReason)
            if ok {
                isLocked = false
                SessionSearch.setAppLocked(false)
                SessionSearch.openIndex()
                lastError = nil
                onUnlock?()
                // Otherwise the next idle check would see a stale (very old)
                // `lastActivity` from before the app was locked and put the
                // lock screen right back up.
                lastActivity = Date()
                // The sheet can leave no window key; hand focus back.
                if NSApp.isActive { MainWindow.makeKey() }
            }
        } catch {
            let detail = error.localizedDescription
            if let laError = error as? LAError,
               [.userCancel, .appCancel, .systemCancel].contains(laError.code) {
                promptGate.userCancelled()
                // Cancelling is not an error: the lock screen stays a bare symbol.
                lastError = nil
            } else {
                onUnlockFailed?(detail)
                lastError = detail
            }
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

    /// The Mac sleeping, its screen locking, or a switch to another user
    /// re-lock immediately: those mean the user has left the Mac. See
    /// `RelockTrigger` for what deliberately does not.
    private func observeRelockTriggers() {
        for trigger in RelockTrigger.allCases {
            let center: NotificationCenter = trigger.isDistributed
                ? DistributedNotificationCenter.default()
                : NSWorkspace.shared.notificationCenter
            let observer = center.addObserver(forName: trigger.notificationName, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.lockIfEnabled() }
            }
            if trigger.isDistributed {
                distributedObservers.append(observer)
            } else {
                workspaceObservers.append(observer)
            }
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
