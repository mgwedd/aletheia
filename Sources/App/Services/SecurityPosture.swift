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
        /// Encryption was turned on but the keystore file is gone.
        encryptionKeystoreMissing: Bool = false,
        /// False in a build without at-rest encryption (and no folder encrypted):
        /// there is nothing to turn on, so the item is left out.
        encryptionOffered: Bool = true,
        auditLogActive: Bool,
        auditLogVerifiable: Bool = true,
        localEncryptedBackup: Bool,
        localBackupActive: Bool,
        iCloudBackupEnabled: Bool,
        iCloudBackupConfigured: Bool,
        networkOnline: Bool?,
        /// Whether the data folder's volume reports as encrypted; nil = unknown.
        diskEncrypted: Bool? = nil
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

        // Automatic logoff (only meaningful once app lock is on): the Mac's screen
        // lock provides it; the in-app idle lock is an optional extra.
        if appLockEnabled {
            if idleAutoLockMinutes > 0 {
                items.append(PostureItem(id: "idleAutoLock", title: "Automatic logoff", level: .secure,
                    detail: "Aletheia locks when your Mac locks or sleeps, and after \(idleAutoLockMinutes) minute\(idleAutoLockMinutes == 1 ? "" : "s") without activity."))
            } else {
                items.append(PostureItem(id: "idleAutoLock", title: "Automatic logoff", level: .informational,
                    detail: "Aletheia locks when your Mac locks or sleeps, so your Mac's screen-lock setting controls it (System Settings > Lock Screen). You can also turn on an in-app idle lock in Settings."))
            }
        }

        // At-rest encryption (Tier 2).
        if encryptionKeystoreMissing {
            items.append(PostureItem(id: "encryption", title: "At-rest encryption", level: .actionRecommended,
                detail: "This folder was encrypted but its keystore is missing, so its data can't be read or saved. Restore the keystore file or choose another folder."))
        } else if encryptionEnabled && encryptionUnlocked {
            items.append(PostureItem(id: "encryption", title: "At-rest encryption", level: .secure,
                detail: "Notes, transcripts, and any kept audio are encrypted on disk."))
        } else if encryptionEnabled {
            items.append(PostureItem(id: "encryption", title: "At-rest encryption", level: .informational,
                detail: "Encryption is on for this folder; unlock with your passphrase to read its sessions."))
        } else if encryptionOffered {
            items.append(PostureItem(id: "encryption", title: "At-rest encryption", level: .actionRecommended,
                detail: "Turn on at-rest encryption for defense in depth beyond FileVault."))
        }

        // Audit log.
        let auditLevel: PostureLevel
        let auditDetail: String
        if !auditLogActive {
            auditLevel = .informational
            auditDetail = "Choose a data folder to begin recording the on-device audit log."
        } else if auditLogVerifiable {
            auditLevel = .secure
            auditDetail = "Security-relevant actions are recorded on this Mac (no names or clinical content)."
        } else {
            auditLevel = .actionRecommended
            auditDetail = "Security-relevant actions are recorded, but integrity is unverifiable because the signing key is unavailable."
        }
        items.append(PostureItem(id: "auditLog", title: "Audit log",
            level: auditLevel,
            detail: auditDetail))

        // Backups Aletheia makes itself. Listed only once something actually
        // writes them: a row about a copy this build can't make would be advice
        // or a claim about a feature that isn't there, and a saved preference
        // must never read as a protection that exists.
        if localBackupActive {
            items.append(PostureItem(id: "encryptedBackup", title: "Encrypted backup",
                level: localEncryptedBackup ? .secure : .informational,
                detail: localEncryptedBackup
                    ? "An end-to-end-encrypted backup copy is kept, sealed with your key."
                    : "Consider keeping an encrypted backup copy, safe to sit in Time Machine. Keep Time Machine backups on an encrypted disk."))
        }

        // Off-device copy in the user's private iCloud (CloudKit): only when it is
        // on and provisioned. Only ciphertext leaves the Mac.
        let cloudBackupActive = iCloudBackupEnabled && iCloudBackupConfigured
        if cloudBackupActive {
            items.append(PostureItem(id: "cloudBackup", title: "Encrypted iCloud backup", level: .secure,
                detail: "An end-to-end-encrypted copy syncs to your private iCloud. It's sealed with your key first, so only ciphertext ever leaves this Mac."))
        }

        // FileVault: read in-process from the data folder's volume
        // (`DiskEncryptionProbe`). Unknown stays a standing recommendation.
        switch diskEncrypted {
        case .some(true):
            items.append(PostureItem(id: "fileVault", title: "FileVault", level: .secure,
                detail: "The disk holding your data folder is encrypted."))
        case .some(false):
            items.append(PostureItem(id: "fileVault", title: "FileVault", level: .actionRecommended,
                detail: "The disk holding your data folder isn't encrypted. Turn on FileVault in System Settings, or encrypt the external drive the folder is on; until then Aletheia won't add new patients, sessions or recordings."))
        case .none:
            items.append(PostureItem(id: "fileVault", title: "FileVault", level: .informational,
                detail: "Aletheia couldn't confirm whether the disk is encrypted. Check that FileVault is on in System Settings."))
        }

        // Network activity: connectivity itself is never a problem to fix here —
        // PHI never traverses the network whatever the state — so this stays
        // informational and only phrases what (if anything) leaves.
        let leaving = cloudBackupActive ? " Only end-to-end-encrypted backups leave." : ""
        let networkDetail: String
        switch networkOnline {
        case .some(true):
            networkDetail = "This Mac is online, but no patient data is sent. Transcription and AI run locally." + leaving
        case .some(false):
            networkDetail = "This Mac is offline. Aletheia is fully functional without a network."
        case .none:
            networkDetail = "No patient data is sent over the network. Transcription and AI run locally." + leaving
        }
        items.append(PostureItem(id: "network", title: "Network activity", level: .informational,
            detail: networkDetail))

        // Standing on-device guarantee — reassurance, always true by design.
        items.append(PostureItem(id: "onDevice", title: "On-device only", level: .secure,
            detail: "All transcription and note generation run on this Mac's own hardware."))

        return items
    }

    /// The headline level: `actionRecommended` if any item asks for action,
    /// otherwise `secure`. Informational items never downgrade the headline.
    static func overall(_ items: [PostureItem]) -> PostureLevel {
        items.contains { $0.level == .actionRecommended } ? .actionRecommended : .secure
    }
}
