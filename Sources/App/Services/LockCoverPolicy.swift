import Foundation

/// Which cover a window that shows patient data needs. One policy for every such
/// window (the main window and the patient chat window), so a window can't be
/// added that forgets to hide patient data while the app is locked.
enum LockCoverPolicy {
    enum Cover: Equatable {
        /// Touch ID / password.
        case appLock
        /// Passphrase for an encrypted data folder.
        case passphrase
    }

    /// Which covers apply, highest-priority (topmost) first. The app lock wins;
    /// it sits above everything. The passphrase cover applies only when a data
    /// folder is chosen and its keystore is still locked.
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

    /// The topmost cover that should be visible in front of everything else, or
    /// nil when the window is uncovered.
    static func topCover(
        appLocked: Bool,
        hasDataFolder: Bool,
        encryption: EncryptionManager.State
    ) -> Cover? {
        cover(appLocked: appLocked, hasDataFolder: hasDataFolder, encryption: encryption).first
    }
}
