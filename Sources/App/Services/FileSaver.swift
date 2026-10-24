import AppKit
import UniformTypeIdentifiers

/// How a save through the panel ended: written to a file, cancelled, or failed.
enum SaveOutcome: Equatable {
    case saved(URL)
    case cancelled
    case failed(String)

    /// What to show the therapist afterwards: nothing for a cancelled save.
    var shown: SaveOutcome? { self == .cancelled ? nil : self }
}

/// Saves text to a user-chosen location via NSSavePanel. Under App Sandbox
/// the user-selected-read-write entitlement covers writing to whatever file
/// the panel returns, so no security-scoped bookmark is needed for a
/// one-shot save.
enum FileSaver {
    static func saveText(_ text: String, suggestedName: String) -> SaveOutcome {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if let markdown = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdown, .plainText]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        return write(Data(text.utf8), to: url)
    }

    /// Saves bytes to a user-chosen location via NSSavePanel, restricted to
    /// `type` (a PDF, a Word document, ...).
    static func saveData(_ data: Data, suggestedName: String, type: UTType) -> SaveOutcome {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        return write(data, to: url)
    }

    /// Writes the file the panel chose.
    static func write(_ data: Data, to url: URL) -> SaveOutcome {
        do {
            try data.write(to: url, options: .atomic)
            return .saved(url)
        } catch {
            return .failed("\(url.lastPathComponent) couldn't be saved. \(error.localizedDescription)")
        }
    }

    /// Asks where to save a file of `type` without writing anything, for work that
    /// runs afterwards (a long export). Under App Sandbox the chosen URL stays
    /// writable for the rest of the session.
    static func chooseDestination(suggestedName: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [type]
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks for a folder to export into. Under App Sandbox the chosen folder
    /// stays writable for the rest of the session.
    static func chooseFolder(prompt: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks for one file with the given extension (a backup to restore).
    static func chooseFile(prompt: String, message: String, fileExtension: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        if let type = UTType(filenameExtension: fileExtension) { panel.allowedContentTypes = [type] }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Saves an iCalendar (.ics) file to a user-chosen location via NSSavePanel.
    @discardableResult
    static func saveICS(_ text: String, suggestedName: String) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if let ics = UTType(filenameExtension: "ics") {
            panel.allowedContentTypes = [ics, .plainText]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Turns a patient name + date into a filesystem-friendly base filename.
    static func fileName(_ parts: String...) -> String {
        let joined = parts.joined(separator: " - ")
        let cleaned = joined.map { char -> Character in
            "/\\:*?\"<>|".contains(char) ? "-" : char
        }
        return String(cleaned)
    }
}
