import SwiftUI

/// The one Export control: a button that opens a short list of formats, PDF
/// selected, and exports in the one picked.
struct ExportButton: View {
    var title: String = "Export"
    var help: String = "Save a copy as a PDF, Word or Markdown file"
    var onExport: (ExportFormat) -> Void

    @State private var showsFormats = false
    @State private var format = ExportFormat.default

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
                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
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
                }
            }
            .buttonStyle(.themed)
            .padding(14)
            .frame(width: 190)
        }
    }
}
