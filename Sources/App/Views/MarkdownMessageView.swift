import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// How `MarkdownMessageView` sets its text. `.reading` is the sans chat-answer
/// look; `.note` is the serif look of a generated progress note. Code and
/// diagram cards are unaffected by the style and stay monospaced.
enum MarkdownTextStyle: Equatable {
    case reading
    case note

    /// Font for paragraphs, list rows and quotes. `nil` leaves the font the
    /// surrounding view provides (the chat look, unchanged).
    var bodyFont: Font? {
        switch self {
        case .reading: return nil
        case .note: return Theme.Typography.noteBody
        }
    }

    /// Extra line spacing for text blocks. `nil` leaves the inherited value.
    var lineSpacing: CGFloat? {
        switch self {
        case .reading: return nil
        case .note: return Theme.Typography.noteLineSpacing
        }
    }

    /// Gap between top-level blocks. A note's paragraph gap is clearly larger
    /// than its line spacing, so paragraphs read as paragraphs.
    var blockSpacing: CGFloat {
        switch self {
        case .reading: return 8
        case .note: return 14
        }
    }

    /// Gap between the rows of a list. In a note it's a little more than the
    /// line spacing, so a wrapped item doesn't run into the next one.
    var listSpacing: CGFloat {
        switch self {
        case .reading: return 4
        case .note: return 8
        }
    }

    func headingFont(_ level: Int) -> Font {
        switch self {
        case .note:
            // Section headings (`##`) take the note heading; the smaller labels
            // `NoteMarkdown` makes (`###`) are semibold body text.
            return level <= 2 ? Theme.Typography.noteHeading : Theme.Typography.noteBody.weight(.semibold)
        case .reading:
            switch level {
            case 1: return .title2.bold()
            case 2: return .title3.bold()
            case 3: return .headline
            default: return .subheadline.bold()
            }
        }
    }

    /// Space above a heading.
    func headingTopPadding(_ level: Int) -> CGFloat {
        switch self {
        case .reading: return level <= 2 ? 2 : 0
        case .note: return level <= 2 ? 12 : 4
        }
    }

    /// Pulls the block after a heading closer than the normal block gap, so a
    /// heading groups with what it introduces. Zero for chat answers.
    var headingBottomPadding: CGFloat {
        switch self {
        case .reading: return 0
        case .note: return -6
        }
    }

    /// The text actually rendered: a note is tidied first (preamble dropped,
    /// paragraphs and labels made explicit; see `NoteMarkdown`). Chat answers
    /// render as written.
    func prepared(_ text: String) -> String {
        switch self {
        case .reading: return text
        case .note: return NoteMarkdown.tidy(text)
        }
    }
}

/// Applies `lineSpacing` only when a value is given, so the chat style inherits
/// whatever the surrounding view set rather than overriding it with zero.
private struct OptionalLineSpacing: ViewModifier {
    let value: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let value {
            content.lineSpacing(value)
        } else {
            content
        }
    }
}

/// Renders a Markdown string (an assistant chat answer) as native SwiftUI, so a
/// local model's headings, emphasis, lists, quotes, and code read like a
/// well-set document instead of raw ``` fences and `**stars**`.
///
/// Block structure comes from `MarkdownParser` (pure, tested); inline markup is
/// handed to Apple's own `AttributedString(markdown:)`, so there's no
/// third-party Markdown engine and nothing to keep in sync with a spec. Fenced
/// code renders as a copyable code card. A ```mermaid block the system prompt
/// invites is drawn as a real diagram — flowcharts and sequence diagrams, laid
/// out and painted natively (see `MermaidDiagram`), with no web view or script —
/// on a `MermaidCard` that toggles between the drawing and its source and copies
/// the diagram as a picture (plus its source as text). One that can't be drawn
/// (unsupported type, malformed, still streaming in) shows its source in the
/// same card, with no error text.
///
/// It re-parses on each streamed update; parsing is cheap and a partial document
/// is always valid input (see `MarkdownParser`), so the answer formats live as
/// it streams in.
struct MarkdownMessageView: View {
    let text: String
    var style: MarkdownTextStyle = .reading

    var body: some View {
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            let blocks = MarkdownParser.parse(style.prepared(text))
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text, font: style.headingFont(level))
                .padding(.top, style.headingTopPadding(level))
                .padding(.bottom, style.headingBottomPadding)

        case let .paragraph(text):
            inline(text, font: style.bodyFont)
                .modifier(OptionalLineSpacing(value: style.lineSpacing))
                .fixedSize(horizontal: false, vertical: true)

        case let .bulleted(items):
            VStack(alignment: .leading, spacing: style.listSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: Text("•"), content: item)
                }
            }

        case let .numbered(items):
            VStack(alignment: .leading, spacing: style.listSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    listRow(marker: Text("\(index + 1)."), content: item)
                }
            }

        case let .quote(lines):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.muted.color.opacity(0.45))
                    .frame(width: 3)
                inline(lines.joined(separator: "\n"), font: style.bodyFont)
                    .modifier(OptionalLineSpacing(value: style.lineSpacing))
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case let .code(language, code):
            if block.isMermaid {
                // Drawn when it parses; otherwise the card shows the source.
                MermaidCard(
                    source: code,
                    diagram: MermaidDiagram.parse(code),
                    context: style == .note ? .note : .ask
                )
            } else {
                CodeCard(language: language, code: code)
            }

        case .rule:
            Rectangle()
                .fill(Theme.line.color)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func listRow(marker: Text, content: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            styled(marker, font: style.bodyFont)
                .monospacedDigit()
                .foregroundStyle(Theme.muted.color)
            inline(content, font: style.bodyFont)
                .modifier(OptionalLineSpacing(value: style.lineSpacing))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Sets `font` on a run of text, or leaves the inherited font when `nil`.
    private func styled(_ text: Text, font: Font?) -> Text {
        guard let font else { return text }
        return text.font(font)
    }

    /// Inline markup (bold, italic, inline code, links) via Apple's own parser,
    /// preserving soft line breaks. Falls back to the raw string if it can't be
    /// interpreted — a half-streamed `**bold` shows its literal text rather than
    /// vanishing.
    private func inline(_ string: String, font: Font? = nil) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: string, options: options) {
            return styled(Text(attributed), font: font)
        }
        return styled(Text(string), font: font)
    }
}

/// A fenced code block: monospaced body on a subtle card, with a caption row
/// that names the language and offers one-click copy.
private struct CodeCard: View {
    let language: String?
    let code: String

    @State private var copied = false

    private var caption: String {
        language?.capitalized ?? "Code"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(caption, systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Theme.muted.color)
                Spacer()
                Button {
                    copy()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.muted.color)
                .help("Copy to clipboard")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.window.color)

            Theme.line.color.frame(height: 1)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(.callout, design: .monospaced))
                    .lineSpacing(0)
                    .foregroundStyle(Theme.text.color)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.field.color)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.line.color, lineWidth: 1)
        )
    }

    private func copy() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #endif
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}
