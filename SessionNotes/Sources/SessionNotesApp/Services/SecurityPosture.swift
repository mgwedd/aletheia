import Foundation

/// How a single posture check reads. `secure` = the protection is on;
/// `actionRecommended` = something the user can do right now would harden things;
/// `informational` = context or a state that isn't a problem to fix (encryption
/// locked this session, a standing on-device guarantee).
enum PostureLevel {
    case secure
    case actionRecommended
    case informational
}

/// One line in the security overview.
struct PostureItem: Identifiable, Equatable {
    /// Stable key, so SwiftUI identity doesn't depend on the (localized) title.
    let id: String
    let title: String
    let level: PostureLevel
    let detail: String
}

/// Rolls the app's security-relevant state up into a plain-language checklist for
/// the Settings "Security overview". Pure and value-typed — no env objects, no
/// I/O — so the mapping from state to advice is unit-testable in isolation. The
/// view feeds it the current settings/encryption/lock state and renders the
/// result; it makes no changes itself.
enum SecurityPosture {
    static func evaluate(
        appLockEnabled: Bool,
        canAuthenticate: Bool,
        idleAutoLockMinutes: Int,
        encryptionEnabled: Bool,
        encryptionUnlocked: Bool,
        auditLogActive: Bool,
        localEncryptedBackup: Bool
    ) -> [PostureItem] {
        var items: [PostureItem] = []

        // App lock (Touch ID / password on open).
        if appLockEnabled && canAuthenticate {
            items.append(PostureItem(id: "appLock", title: "App lock", level: .secure,
                detail: "The app requires Touch ID or your password to open."))
        } else if appLockEnabled {
            items.append(PostureItem(id: "appLock", title: "App lock", level: .actionRecommended,
                detail: "App lock is on, but this Mac can't authenticate. Set a login password or Touch ID so the lock can engage."))
        } else {
            items.append(PostureItem(id: "appLock", title: "App lock", level: .actionRecommended,
                detail: "Require Touch ID or your password to open the app, so notes stay behind authentication."))
        }

        // Idle auto-lock (only meaningful once app lock is on).
        if appLockEnabled {
            if idleAutoLockMinutes > 0 {
                items.append(PostureItem(id: "idleAutoLock", title: "Automatic logoff", level: .secure,
                    detail: "Re-locks after \(idleAutoLockMinutes) minute\(idleAutoLockMinutes == 1 ? "" : "s") of inactivity."))
            } else {
                items.append(PostureItem(id: "idleAutoLock", title: "Automatic logoff", level: .actionRecommended,
                    detail: "Idle auto-lock is off. Set a timeout so the app re-locks when you step away."))
            }
        }

        // At-rest encryption (Tier 2).
        if encryptionEnabled && encryptionUnlocked {
            items.append(PostureItem(id: "encryption", title: "At-rest encryption", level: .secure,
                detail: "Notes, transcripts, and any kept audio are encrypted on disk."))
        } else if encryptionEnabled {
            items.append(PostureItem(id: "encryption", title: "At-rest encryption", level: .informational,
                detail: "Encryption is on for this folder; unlock with your passphrase to read its sessions."))
        } else {
            items.append(PostureItem(id: "encryption", title: "At-rest encryption", level: .actionRecommended,
                detail: "Turn on at-rest encryption for defense in depth beyond FileVault."))
        }

        // Audit log.
        items.append(PostureItem(id: "auditLog", title: "Audit log",
            level: auditLogActive ? .secure : .informational,
            detail: auditLogActive
                ? "Security-relevant actions are recorded on this Mac (no names or clinical content)."
                : "Choose a data folder to begin recording the on-device audit log."))

        // Encrypted backup copy.
        items.append(PostureItem(id: "encryptedBackup", title: "Encrypted backup",
            level: localEncryptedBackup ? .secure : .informational,
            detail: localEncryptedBackup
                ? "An end-to-end-encrypted backup copy is kept, sealed with your key."
                : "Consider keeping an encrypted backup copy, safe to sit in Time Machine."))

        // FileVault: the app can't read its state under the sandbox, so this is a
        // standing recommendation with a link elsewhere in Settings.
        items.append(PostureItem(id: "fileVault", title: "FileVault", level: .informational,
            detail: "Full-disk encryption is recommended as the baseline. Manage it in System Settings."))

        // Standing on-device guarantee — reassurance, always true by design.
        items.append(PostureItem(id: "onDevice", title: "On-device only", level: .secure,
            detail: "All transcription and AI run on this Mac. No patient data is sent to the cloud."))

        return items
    }

    /// The headline level: `actionRecommended` if any item asks for action,
    /// otherwise `secure`. Informational items never downgrade the headline.
    static func overall(_ items: [PostureItem]) -> PostureLevel {
        items.contains { $0.level == .actionRecommended } ? .actionRecommended : .secure
    }
}
