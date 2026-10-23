import AppKit
import PDFKit
import UniformTypeIdentifiers

/// The printable / savable sheet that carries a folder's 24-word recovery key,
/// and the copy, save and print actions the setup and replace sheets share.
enum RecoveryKeyDocument {
    static let title = "Aletheia — Emergency Recovery Key"
    static let subtitle = "Confidential • Store Securely"
    static let suggestedFileName = "Aletheia - Recovery Key.pdf"

    /// Markdown for the recovery-key sheet: every word, numbered, in order.
    static func markdown(key: String, folderName: String, created: Date, replacesPrevious: Bool) -> String {
        let dateStr = DateFormatter.localizedString(from: created, dateStyle: .medium, timeStyle: .short)
        let wordList = RecoveryKey.words(from: key).enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let replaceLine = replacesPrevious ? "\n- This recovery key replaces any previously issued recovery key." : ""
        return """
        # Emergency Recovery Key

        Keep this document in a safe, offline place (such as a locked fireproof safe or safety deposit box).

        - **Data folder:** \(folderName)
        - **Created:** \(dateStr)

        ### 24-Word Recovery Key

        \(wordList)

        ---

        ### Important Safeguards\(replaceLine)
        - This recovery key provides emergency access to your encrypted patient records.
        - If you forget your passphrase, these 24 words are the only way to regain access.
        - Aletheia never stores this recovery key in the data folder or on any server.
        - Store this document in a secure location separate from your Mac.
        """
    }

    /// Whether `destination` lies inside the encrypted data folder. A plaintext
    /// copy of the key saved beside the keystore would unlock the folder for
    /// anyone holding a copy of it (a backup, a synced drive), so it's refused.
    static func isInsideDataFolder(_ destination: URL, dataRoot: URL?) -> Bool {
        guard let dataRoot else { return false }
        let root = dataRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        // The file doesn't exist yet, so resolve the folder it goes in.
        let folder = destination.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let target = folder.appendingPathComponent(destination.lastPathComponent).pathComponents
        return target.count >= root.count && Array(target.prefix(root.count)) == root
    }

    static let insideDataFolderMessage =
        "Save the recovery key outside your encrypted data folder — a copy kept beside your data would unlock it."

    /// Copies the words to this Mac's pasteboard only, marked so clipboard
    /// managers don't keep them.
    static func copy(_ key: String, to pasteboard: NSPasteboard = PHIPasteboard.general) {
        PHIPasteboard.writeString(key, to: pasteboard)
    }

    /// Asks where to save the PDF and writes it, unless the chosen place is in
    /// the data folder.
    @MainActor
    static func save(key: String, dataRoot: URL?, replacesPrevious: Bool) -> SaveOutcome {
        guard let data = pdf(key: key, dataRoot: dataRoot, replacesPrevious: replacesPrevious) else {
            return .failed("The recovery key PDF couldn't be created.")
        }
        guard let url = FileSaver.chooseDestination(suggestedName: suggestedFileName, type: .pdf) else {
            return .cancelled
        }
        return write(data, to: url, dataRoot: dataRoot)
    }

    /// Writes the PDF to `url`, refusing a destination inside the data folder.
    static func write(_ data: Data, to url: URL, dataRoot: URL?) -> SaveOutcome {
        if isInsideDataFolder(url, dataRoot: dataRoot) { return .failed(insideDataFolderMessage) }
        return FileSaver.write(data, to: url)
    }

    @MainActor
    static func print(key: String, dataRoot: URL?, replacesPrevious: Bool) {
        guard let data = pdf(key: key, dataRoot: dataRoot, replacesPrevious: replacesPrevious),
              let document = PDFDocument(data: data) else { return }
        let printInfo = NSPrintInfo.shared
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        if let op = document.printOperation(for: printInfo, scalingMode: .pageScaleToFit, autoRotate: true) {
            op.showsPrintPanel = true
            op.run()
        }
    }

    @MainActor
    private static func pdf(key: String, dataRoot: URL?, replacesPrevious: Bool) -> Data? {
        let markdown = markdown(
            key: key,
            folderName: dataRoot?.lastPathComponent ?? "Aletheia Data",
            created: Date(),
            replacesPrevious: replacesPrevious
        )
        return NotePDF.render(markdown: markdown, title: title, subtitle: subtitle)
    }
}
