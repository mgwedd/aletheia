import AppKit

/// Wraps NSOpenPanel so the therapist can pick (or create) the folder that
/// holds all patient data. Suggesting the iCloud Drive location by default
/// is what makes backup "automatic" without the app needing an iCloud
/// container entitlement (which would require a paid Apple Developer
/// account) — it's just a normal folder the user grants access to.
enum FolderPicker {
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Your Aletheia Folder"
        panel.message = "Pick a folder inside iCloud Drive so your notes back up automatically, or choose any folder you like. Use \"New Folder\" to create one."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"

        let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: iCloudDrive.path) {
            panel.directoryURL = iCloudDrive
        }

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
