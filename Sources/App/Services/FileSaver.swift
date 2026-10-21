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

    /// Saves PDF bytes to a user-chosen location via NSSavePanel.
    @discardableResult
    static func savePDF(_ data: Data, suggestedName: String) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
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
