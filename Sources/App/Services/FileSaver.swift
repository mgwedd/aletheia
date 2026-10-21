import AppKit
import UniformTypeIdentifiers

/// Saves text to a user-chosen location via NSSavePanel. Under App Sandbox
/// the user-selected-read-write entitlement covers writing to whatever file
/// the panel returns, so no security-scoped bookmark is needed for a
/// one-shot save.
enum FileSaver {
    @discardableResult
    static func saveText(_ text: String, suggestedName: String) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if let markdown = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdown, .plainText]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Saves bytes to a user-chosen location via NSSavePanel, restricted to
    /// `type` (a PDF, a Word document, ...).
    @discardableResult
    static func saveData(_ data: Data, suggestedName: String, type: UTType) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
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
