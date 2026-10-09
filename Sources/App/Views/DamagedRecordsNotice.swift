import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// A calm, non-blocking notice for patient/session records the store found but
/// couldn't read (see `UnreadableEntry`). It explains what happened, that the
/// original file was left untouched, and where it lives. Nothing here deletes or
/// repairs anything.
struct DamagedRecordsNotice: View {
    let title: String
    let entries: [UnreadableEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Typography.control)
                .foregroundStyle(Theme.callAudio.color)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.message)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.text.color)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(entry.fileURL.path)
                                .font(Theme.Typography.caption.monospaced())
                                .foregroundStyle(Theme.muted.color)
                                .textSelection(.enabled)
                            #if canImport(AppKit)
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([entry.folder])
                            }
                            .buttonStyle(.link)
                            .font(Theme.Typography.caption)
                            #endif
                        }
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.callout.color, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.callAudio.color.opacity(0.4)))
    }
}
