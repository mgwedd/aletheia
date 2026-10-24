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
        /// The folder was encrypted but its keystore is gone.
        case keystoreMissing
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
        if hasDataFolder && encryption == .keystoreMissing { covers.append(.keystoreMissing) }
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

    /// Whether the content under the covers may be used. While the app is locked
    /// the covers only hide it; this also takes away hit testing, keyboard focus
    /// and Accessibility, so nothing behind the cover can be reached.
    static func contentInteractionEnabled(isLocked: Bool) -> Bool { !isLocked }

    /// Whether the window's first responder is dropped when the lock changes to
    /// `isLocked`, so Copy and Select All have nothing to act on.
    static func resignsFirstResponder(onLockChangingTo isLocked: Bool) -> Bool { isLocked }

    /// The app-menu commands defined in `AletheiaApp.commands`. A command that
    /// acts on patient content or opens a window showing it must be listed in
    /// `disabledWhileLocked`.
    enum MenuCommand: CaseIterable {
        case closeWindow
        case checkForUpdates
        case showShortcuts
        case openDoctor
        case reportBug
        case requestFeature

        /// Opens a window that shows data from the data folder.
        var actsOnContent: Bool { self == .openDoctor }
    }

    /// Whether `command` is greyed out in the menu.
    static func commandDisabled(_ command: MenuCommand, isLocked: Bool) -> Bool {
        isLocked && command.actsOnContent
    }
}
