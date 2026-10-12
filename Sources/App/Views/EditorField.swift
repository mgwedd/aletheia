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
    /// Take focus when it appears, with the caret at the end of the text.
    var autofocus = false

    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(Theme.Typography.body)
            .lineSpacing(4)
            .foregroundStyle(Theme.text.color)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .autofocusAtEnd(autofocus, focus: $focused)
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

/// Moves keyboard focus to a field when its view appears and puts the caret
/// after the last character. SwiftUI's `TextField` and `TextEditor` select all
/// of their text on focus, and macOS 14 has no API to place the caret, so this
/// reaches the underlying text view.
private struct AutofocusAtEnd: ViewModifier {
    let enabled: Bool
    var focus: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content.onAppear {
            guard enabled else { return }
            // The sheet needs a beat to become the key window before focus sticks.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focus.wrappedValue = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    CaretPlacement.moveToEnd()
                }
            }
        }
    }
}

extension View {
    /// See `AutofocusAtEnd`.
    func autofocusAtEnd(_ enabled: Bool, focus: FocusState<Bool>.Binding) -> some View {
        modifier(AutofocusAtEnd(enabled: enabled, focus: focus))
    }
}

enum CaretPlacement {
    /// Collapses the focused text view's selection to the end of its text.
    /// A single-line `TextField` edits through the window's field editor, which
    /// is also an `NSTextView`, so one path covers both.
    static func moveToEnd() {
        moveToEnd(in: NSApp.keyWindow?.firstResponder as? NSTextView)
    }

    /// The part that is unit-tested: place the caret after the last character.
    /// Uses the UTF-16 length, which is what `NSRange` counts.
    static func moveToEnd(in textView: NSTextView?) {
        guard let textView else { return }
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
    }
}
