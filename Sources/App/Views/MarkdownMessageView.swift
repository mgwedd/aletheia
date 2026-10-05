import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Renders a Markdown string (an assistant chat answer) as native SwiftUI, so a
/// local model's headings, emphasis, lists, quotes, and code read like a
/// well-set document instead of raw ``` fences and `**stars**`.
///
/// Block structure comes from `MarkdownParser` (pure, tested); inline markup is
/// handed to Apple's own `AttributedString(markdown:)`, so there's no
/// third-party Markdown engine and nothing to keep in sync with a spec. Fenced
/// code — including the ```mermaid diagrams the system prompt invites — renders
/// as a copyable code card; a Mermaid block is labeled as a diagram so its
/// source reads as intentional rather than as leaked markup.
///
/// It re-parses on each streamed update; parsing is cheap and a partial document
/// is always valid input (see `MarkdownParser`), so the answer formats live as
/// it streams in.
struct MarkdownMessageView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let blocks = MarkdownParser.parse(text)
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
            inline(text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 2 : 0)

        case let .paragraph(text):
            inline(text)
                .fixedSize(horizontal: false, vertical: true)

        case let .bulleted(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: Text("•"), content: item)
                }
            }

        case let .numbered(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    listRow(marker: Text("\(index + 1)."), content: item)
                }
            }

        case let .quote(lines):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                inline(lines.joined(separator: "\n"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case let .code(language, code):
            CodeCard(language: language, code: code, isMermaid: block.isMermaid)

        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func listRow(marker: Text, content: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker
                .monospacedDigit()
                .foregroundStyle(.secondary)
            inline(content)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        case 3: return .headline
        default: return .subheadline.bold()
        }
    }

    /// Inline markup (bold, italic, inline code, links) via Apple's own parser,
    /// preserving soft line breaks. Falls back to the raw string if it can't be
    /// interpreted — a half-streamed `**bold` shows its literal text rather than
    /// vanishing.
    private func inline(_ string: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: string, options: options) {
            return Text(attributed)
        }
        return Text(string)
    }
}

/// A fenced code (or Mermaid diagram) block: monospaced body on a subtle card,
/// with a caption row that names the language and offers one-click copy. Mermaid
/// blocks are captioned as a diagram so their source reads as intentional.
private struct CodeCard: View {
    let language: String?
    let code: String
    let isMermaid: Bool

    @State private var copied = false

    private var caption: String {
        if isMermaid { return "Diagram" }
        return language?.capitalized ?? "Code"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(caption, systemImage: isMermaid ? "point.3.connected.trianglepath.dotted" : "chevron.left.forwardslash.chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copy()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy to clipboard")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.10))

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
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
