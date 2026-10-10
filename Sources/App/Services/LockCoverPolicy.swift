import Foundation

/// Which cover a window that shows patient data needs. One policy for every such
/// window (the main window and the patient chat window), so a window can't be
/// added that forgets to hide patient data while the app is locked.
enum LockCoverPolicy {
    enum Cover: Equatable {
        case none
        /// Touch ID / password.
        case appLock
        /// Passphrase for an encrypted data folder.
        case passphrase
    }

    /// The app lock wins; it sits above everything. The passphrase cover applies
    /// only when a data folder is chosen and its keystore is still locked.
    static func cover(
        appLocked: Bool,
        hasDataFolder: Bool,
        encryption: EncryptionManager.State
    ) -> [Cover] {
        var covers: [Cover] = []
        if appLocked { covers.append(.appLock) }
        if hasDataFolder && encryption == .lockedNeedsPassphrase { covers.append(.passphrase) }
        return covers
    }
}
