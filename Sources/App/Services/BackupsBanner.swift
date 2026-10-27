import Foundation

/// The banner at the top of Settings > Backups. Back Up Now needs at-rest
/// encryption, which released builds do not include, so the banner says who
/// is responsible for a backup rather than pointing at a button that is absent.
enum BackupsBanner {
    static func text(excluded: Bool, backUpNowOffered: Bool) -> String {
        if excluded {
            return backUpNowOffered
                ? "Your data folder is kept out of Time Machine and iCloud backups. Use Back Up Now to save an encrypted copy to a folder on this Mac or an external disk, or turn off the switch below to let Time Machine include the folder."
                : "Your data folder is kept out of Time Machine and iCloud backups, and Back Up Now is not available in this version, so nothing backs it up yet. Arranging a backup is up to you: turn off the switch below to let Time Machine include the folder, onto an encrypted backup disk."
        }
        return backUpNowOffered
            ? "Time Machine includes the data folder. Keep those backups on an encrypted disk. You can also use Back Up Now to save an encrypted copy to a folder of your choice."
            : "Time Machine includes the data folder. Keep those backups on an encrypted disk: Aletheia does not encrypt the folder itself in this version, and Back Up Now is not available."
    }
}
