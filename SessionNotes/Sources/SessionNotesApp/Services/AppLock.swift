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

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        self.isLocked = AppLockPolicy.shouldLock(
            enabled: settings.appLockEnabled,
            canAuthenticate: Self.canAuthenticate()
        )
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
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
