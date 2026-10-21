import SwiftUI

/// The one Export control: a button that opens a short list of formats, PDF
/// checked, and exports in the one picked.
struct ExportButton: View {
    var title: String = "Export"
    var help: String = "Save a copy as a PDF, Word or Markdown file"
    var onExport: (ExportFormat) -> Void

    @State private var showsFormats = false
    @State private var format = ExportFormat.default
    /// Keyboard focus starts on Export (the default action), not on the first
    /// format row: a focus ring on PDF next to a checkmark on Markdown read as
    /// two selections.
    @FocusState private var exportFocused: Bool

    var body: some View {
        Button {
            format = .default
            showsFormats = true
        } label: {
            Label(title, systemImage: "square.and.arrow.up")
        }
        .help(help)
        .popover(isPresented: $showsFormats, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ExportFormat.allCases) { option in
                        Button {
                            format = option
                        } label: {
                            HStack(spacing: 8) {
                                // A fixed-width column, so the names line up whether or not one is checked.
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(width: 14)
                                    .opacity(format == option ? 1 : 0)
                                Text(option.title)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.text.color)
                        .padding(.vertical, 5)
                        .accessibilityAddTraits(format == option ? .isSelected : [])
                    }
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel") { showsFormats = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Export") {
                        let chosen = format
                        showsFormats = false
                        // After the popover is gone, so the save panel isn't opened from inside it.
                        DispatchQueue.main.async { onExport(chosen) }
                    }
                    .buttonStyle(.themePrimary)
                    .keyboardShortcut(.defaultAction)
                    .focused($exportFocused)
                }
            }
            .buttonStyle(.themed)
            .padding(14)
            .frame(width: 190)
            .defaultFocus($exportFocused, true)
            .onAppear { exportFocused = true }
        }
    }
}
