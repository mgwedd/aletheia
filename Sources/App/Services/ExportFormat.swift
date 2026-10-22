import AppKit
import UniformTypeIdentifiers

/// The formats every export in the app offers. PDF is the default; therapists
/// hand these to people who don't read Markdown, so Markdown is the third choice.
enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf
    case word
    case markdown

    static let `default`: ExportFormat = .pdf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdf: return "PDF"
        case .word: return "Word"
        case .markdown: return "Markdown"
        }
    }

    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .word: return "docx"
        case .markdown: return "md"
        }
    }

    var contentType: UTType {
        switch self {
        case .pdf: return .pdf
        case .word: return UTType(filenameExtension: "docx") ?? .data
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        }
    }

    /// `base` with this format's extension.
    func fileName(_ base: String) -> String {
        "\(base).\(fileExtension)"
    }
}

/// What an export is made from: Markdown text, with an optional title block
/// that the formats render in their own way.
struct ExportDocument: Equatable {
    var title: String = ""
    var subtitle: String = ""
    var markdown: String
}

/// Turns an `ExportDocument` into the bytes of a file, entirely on this Mac.
enum ExportRenderer {
    @MainActor
    static func data(for format: ExportFormat, document: ExportDocument) -> Data? {
        switch format {
        case .pdf:
            return NotePDF.render(markdown: document.markdown, title: document.title, subtitle: document.subtitle)
        case .word:
            let text = NotePDF.attributedText(
                markdown: document.markdown, title: document.title, subtitle: document.subtitle
            )
            let attributes: [NSAttributedString.DocumentAttributeKey: Any] = [
                .documentType: NSAttributedString.DocumentType.officeOpenXML,
            ]
            guard let data = try? text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes),
                  !data.isEmpty else { return nil }
            return data
        case .markdown:
            return Data(markdownText(document).utf8)
        }
    }

    /// The Markdown file: the title block as a heading, then the text as given.
    static func markdownText(_ document: ExportDocument) -> String {
        var parts: [String] = []
        if !document.title.isEmpty { parts.append("# \(document.title)") }
        if !document.subtitle.isEmpty { parts.append("_\(document.subtitle)_") }
        parts.append(document.markdown)
        return parts.joined(separator: "\n\n")
    }

    /// Makes the file and asks where to save it.
    @MainActor
    static func save(_ document: ExportDocument, as format: ExportFormat, baseName: String) -> SaveOutcome {
        guard let data = data(for: format, document: document) else {
            return .failed("The \(format.title) file couldn't be made.")
        }
        return FileSaver.saveData(data, suggestedName: format.fileName(baseName), type: format.contentType)
    }
}
