import AppKit

/// Copy for a note: styled text, so it pastes into an EHR or a Word document
/// with its headings and lists rather than as Markdown symbols. The plain-text
/// version (what a text-only field receives) has no markup either.
enum RichClipboard {
    struct Payload {
        var plain: String
        var rtf: Data?
        var html: Data?
    }

    static func payload(markdown: String) -> Payload {
        let styled = NotePDF.attributedText(markdown: NoteMarkdown.tidy(markdown), title: "", subtitle: "")
        let range = NSRange(location: 0, length: styled.length)
        return Payload(
            plain: styled.string.trimmingCharacters(in: .whitespacesAndNewlines),
            rtf: styled.rtf(from: range, documentAttributes: [:]),
            html: try? styled.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        )
    }

    /// Replaces the pasteboard's contents with the payload: plain text always,
    /// rich text and HTML when they could be made.
    static func write(_ payload: Payload, kind: AuditDetail = .note, to pasteboard: NSPasteboard = PHIPasteboard.general) {
        let item = NSPasteboardItem()
        item.setString(payload.plain, forType: .string)
        if let rtf = payload.rtf { item.setData(rtf, forType: .rtf) }
        if let html = payload.html { item.setData(html, forType: .html) }
        PHIPasteboard.write([item], kind: kind, to: pasteboard)
    }
}
