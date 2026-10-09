import SwiftUI
import AppKit

/// A multi-line text box with room to breathe: inner padding so the text and
/// cursor don't sit on the edge, the theme's field surface, an accent border
/// while focused, and an optional placeholder. Used by the profile editor, My Notes
/// and the generated-note editor.
struct EditorField: View {
    @Binding var text: String
    var placeholder: String = ""
    var minHeight: CGFloat = 90
    /// Grow to fill the space offered (a full-pane editor) instead of sizing to `minHeight`.
    var fills = false

    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(Theme.Typography.body)
            .lineSpacing(4)
            .foregroundStyle(Theme.text.color)
            .scrollContentBackground(.hidden)
            .focused($focused)
            // TextEditor insets its text by 5pt; this brings it to the design's
            // 12 × 10 padding.
            .padding(.horizontal, 7)
            .padding(.vertical, 10)
            .frame(minHeight: minHeight, maxHeight: fills ? .infinity : nil)
            .overlay(alignment: .topLeading) {
                if text.isEmpty && !placeholder.isEmpty {
                    Text(placeholder)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.muted.color)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
            .themeField(isFocused: focused)
    }
}
