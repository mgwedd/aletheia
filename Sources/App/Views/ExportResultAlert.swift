import AppKit
import SwiftUI

/// After an export: where the file went, as a link that opens it in whatever
/// app this Mac opens that kind of file with, or why it wasn't saved.
struct ExportResultAlert: View {
    let outcome: SaveOutcome
    var onDismiss: () -> Void
    /// Opens the file; tests pass a fake.
    var open: (URL) -> Void = ExportFileLink.openInDefaultApp

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch outcome {
            case let .saved(url):
                Label("Exported", systemImage: "checkmark.circle.fill")
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.ok.color)
                ExportFileLink(url: url, open: open, onOpen: onDismiss)
                buttons {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        onDismiss()
                    }
                    .buttonStyle(.themed)
                    Button("Done", action: onDismiss)
                        .buttonStyle(.themePrimary)
                        .keyboardShortcut(.defaultAction)
                }
            case let .failed(message):
                Label("Export failed", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.warn.color)
                Text(message)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                buttons {
                    Button("OK", action: onDismiss)
                        .buttonStyle(.themePrimary)
                        .keyboardShortcut(.defaultAction)
                }
            case .cancelled:
                EmptyView()
            }
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
        .background(Theme.window.color)
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            content()
        }
    }
}

/// The exported file's path as a link; clicking it opens the file.
struct ExportFileLink: View {
    let url: URL
    let open: (URL) -> Void
    let onOpen: () -> Void

    init(url: URL, open: @escaping (URL) -> Void = Self.openInDefaultApp, onOpen: @escaping () -> Void = {}) {
        self.url = url
        self.open = open
        self.onOpen = onOpen
    }

    var body: some View {
        Button {
            open(url)
            onOpen()
        } label: {
            Text(Self.displayPath(url))
                .font(Theme.Typography.caption)
                .underline()
                .foregroundStyle(Theme.accent.color)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        .help("Open \(url.lastPathComponent)")
        .accessibilityLabel("Open \(url.lastPathComponent)")
        .accessibilityAddTraits(.isLink)
    }

    /// The path with the home folder shortened to "~".
    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    static func openInDefaultApp(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

extension View {
    /// Shows how an export ended while `outcome` is set; dismissing clears it.
    func exportResultAlert(_ outcome: Binding<SaveOutcome?>) -> some View {
        sheet(isPresented: Binding(get: { outcome.wrappedValue != nil }, set: { if !$0 { outcome.wrappedValue = nil } })) {
            if let shown = outcome.wrappedValue {
                ExportResultAlert(outcome: shown, onDismiss: { outcome.wrappedValue = nil })
            }
        }
    }
}
