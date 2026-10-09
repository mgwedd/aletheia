import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// A calm, non-blocking notice for patient/session records the store found but
/// couldn't read (see `UnreadableEntry`). A warning header says how many, then
/// each record is listed with what happened and where it lives. The original
/// files are never touched: nothing here deletes or repairs anything.
struct DamagedRecordsNotice: View {
    let title: String
    let entries: [UnreadableEntry]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        row(entry)
                        if index < entries.count - 1 {
                            Rectangle().fill(Theme.line.color).frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 220)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel.color, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.line.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.warn.color)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Their original files were left untouched in your data folder.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warnTint.color)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.warn.color).frame(height: 1)
        }
    }

    private func row(_ entry: UnreadableEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Chip("Unreadable", tone: .warn)
                Text(entry.message)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(entry.fileURL.path)
                .font(Theme.Typography.caption.monospaced())
                .foregroundStyle(Theme.muted.color)
                .textSelection(.enabled)
            #if canImport(AppKit)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.folder])
            }
            .buttonStyle(.plain)
            .font(Theme.Typography.control)
            .foregroundStyle(Theme.muted.color)
            .help("Show this record's folder in Finder")
            #endif
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
