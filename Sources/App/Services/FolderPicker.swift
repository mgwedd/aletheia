import AppKit

/// Lets the clinician choose a local folder for patient data.
enum FolderPicker {
    static func choose() -> URL? {
        while true {
            let panel = NSOpenPanel()
            panel.title = "Choose Your Aletheia Folder"
            panel.message = "Choose a folder on this Mac. Use New Folder to create one."
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Use This Folder"
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            let verdict = DataFolderPolicy.verdict(for: url)
            if verdict == .ok { return url }
            let alert = NSAlert()
            alert.messageText = "Choose a local data folder"
            alert.informativeText = verdict.explanation
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Choose Again")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return nil }
        }
    }
}
