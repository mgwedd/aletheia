import SwiftUI

/// Sizes of the single-line input, shared with `ThemeTextArea` so a field and
/// an editor side by side have the same inset.
enum ThemeTextFieldMetrics {
    static let horizontalPadding = ThemeTextAreaMetrics.horizontalPadding
    static let height: CGFloat = 38
}

/// The one single-line text input: plain field in the themed box (field fill,
/// hairline border, accent border while focused).
struct ThemeTextField: View {
    let placeholder: String
    @Binding var text: String
    var accessibilityLabel: String?
    var onSubmit: (() -> Void)?

    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.text.color)
            .focused($focused)
            .padding(.horizontal, ThemeTextFieldMetrics.horizontalPadding)
            .frame(height: ThemeTextFieldMetrics.height)
            .themeField(isFocused: focused)
            .accessibilityLabel(accessibilityLabel ?? placeholder)
            .onSubmit { onSubmit?() }
            .noWritingTools()
    }
}
