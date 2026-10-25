import Foundation
import LocalAuthentication

/// Settings changes that weaken protection or move patient data out of the
/// app's usual guard. Each one needs a fresh Touch ID / Mac password check.
enum SensitiveAction: String, CaseIterable {
    case turnOffAppLock
    case weakenIdleLock
    case disableEncryption
    case changePassphrase
    case changeDataFolder
    case exportActivityLog
    case exportAllRecords

    /// Passed to `evaluatePolicy`. macOS renders the sheet as
    /// "<App> is trying to <reason>.", so these are lowercase-initial, don't
    /// name the app, and have no period.
    var authenticationReason: String {
        switch self {
        case .turnOffAppLock: return "turn off the app lock"
        case .weakenIdleLock: return "lengthen or turn off the automatic lock"
        case .disableEncryption: return "turn off encryption"
        case .changePassphrase: return "change your passphrase"
        case .changeDataFolder: return "change the data folder"
        case .exportActivityLog: return "export the activity log"
        case .exportAllRecords: return "export all records"
        }
    }
}

/// Whether a change to the idle auto-lock timeout makes the lock weaker.
enum IdleLockChange {
    /// A longer wait, or Never, weakens the lock; the same or a shorter wait doesn't.
    static func weakens(from old: IdleAutoLockTimeout, to new: IdleAutoLockTimeout) -> Bool {
        if new == old { return false }
        if new == .off { return true }
        if old == .off { return false }
        return new.rawValue > old.rawValue
    }
}

/// Runs a sensitive action only after the user authenticates again, every time.
/// Nothing is remembered between calls, so a sheet left open or an unlocked Mac
/// can't change these settings without proving who is at the keyboard.
///
/// When this Mac has no Touch ID or password to ask for, the lock itself is not
/// enforced (see `AppLockPolicy.shouldLock`), so the gate lets the action
/// through rather than leaving the user unable to change their own settings.
@MainActor
final class SensitiveActionGate {
    private let authenticator: UnlockAuthenticator
    private let canAuthenticate: () -> Bool
    private var isPrompting = false

    init(
        authenticator: UnlockAuthenticator = UnlockAuthenticatorFactory.make(),
        canAuthenticate: @escaping () -> Bool = { AppLock.canAuthenticate() }
    ) {
        self.authenticator = authenticator
        self.canAuthenticate = canAuthenticate
    }

    /// True only when the user just authenticated. Cancel, failure, or a prompt
    /// already on screen all answer false.
    func authorize(_ action: SensitiveAction) async -> Bool {
        guard canAuthenticate() else { return true }
        guard !isPrompting else { return false }
        isPrompting = true
        defer { isPrompting = false }
        do {
            return try await authenticator.authenticate(reason: action.authenticationReason)
        } catch {
            return false
        }
    }

    /// Runs `body` once if the user authenticates; otherwise never. Returns
    /// whether it ran.
    @discardableResult
    func perform(_ action: SensitiveAction, _ body: @MainActor () -> Void) async -> Bool {
        guard await authorize(action) else { return false }
        body()
        return true
    }
}
