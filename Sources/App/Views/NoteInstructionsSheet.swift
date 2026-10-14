import SwiftUI

/// Edits the instruction text for one note format (see `Prompts.defaultInstructions`).
/// Saving text equal to the default clears the override.
struct NoteInstructionsSheet: View {
    let format: ProgressNoteFormat
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String

    init(format: ProgressNoteFormat, current: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.format = format
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: current)
    }

    private var defaultText: String { Prompts.defaultInstructions(for: format) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(format.shortName) prompt")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.text.color)
            Text("Instructions for drafting this format. The transcript, your notes and comments, and the length setting are added automatically after these.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.text.color)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 280)
                .themeField()
            HStack {
                Button("Reset to Default") { text = defaultText }
                    .disabled(text == defaultText)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(text) }
                    .buttonStyle(.themePrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.themed)
        }
        .padding(20)
        .frame(minWidth: 560)
        .background(Theme.window.color)
    }
}
