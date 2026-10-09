import SwiftUI
import AppKit

/// A multi-line text box with room to breathe: inner padding so the text and
/// cursor don't sit on the edge, a rounded surface, an accent ring while
/// focused, and an optional placeholder. Used by the profile editor, My Notes
/// and the generated-note editor.
struct EditorField: View {
    @Binding var text: String
    var placeholder: String = ""
    var minHeight: CGFloat = 90
    /// Grow to fill the space offered (a full-pane editor) instead of sizing to `minHeight`.
    var fills = false

    @FocusState private var focused: Bool

    private let corner: CGFloat = 8

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .frame(minHeight: minHeight, maxHeight: fills ? .infinity : nil)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: corner))
            .overlay(alignment: .topLeading) {
                if text.isEmpty && !placeholder.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: corner)
                    .stroke(focused ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: focused ? 2 : 1)
            )
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}
