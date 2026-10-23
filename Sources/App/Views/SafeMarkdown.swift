import SwiftUI

/// Inline Markdown for model-written text. Link runs are removed (the visible
/// text stays), so nothing a model writes can be clicked, and no address in it
/// is ever handed to the system.
enum SafeMarkdown {
    static func attributed(from string: String) -> AttributedString? {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard var parsed = try? AttributedString(markdown: string, options: options) else { return nil }
        let linked = parsed.runs.filter { $0.link != nil }.map(\.range)
        for range in linked { parsed[range].link = nil }
        return parsed
    }
}

extension View {
    /// Discards every link-open request from this view's text.
    func discardingLinks() -> some View {
        environment(\.openURL, OpenURLAction { _ in .discarded })
    }
}
