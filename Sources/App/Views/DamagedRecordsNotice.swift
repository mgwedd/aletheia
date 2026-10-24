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
    var onDismiss: ((UnreadableEntry) -> Void)? = nil

    @State private var reviewingEntry: UnreadableEntry?

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
        .dismissOnLock { reviewingEntry = nil }
        .sheet(item: $reviewingEntry) { entry in
            DamagedRecordReviewSheet(
                entry: entry,
                onDismissNotice: {
                    onDismiss?(entry)
                    reviewingEntry = nil
                },
                onClose: {
                    reviewingEntry = nil
                }
            )
        }
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
                Text("The original records were left untouched in your data folder.")
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
                Text(entry.shortDescription)
                    .font(Theme.Typography.caption.weight(.medium))
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(entry.fileURL.path)
                .font(Theme.Typography.caption.monospaced())
                .foregroundStyle(Theme.muted.color)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Button("Review") {
                    reviewingEntry = entry
                }
                .buttonStyle(.themed)
                .controlSize(.small)

                if onDismiss != nil {
                    Button("Dismiss") {
                        onDismiss?(entry)
                    }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.muted.color)
                    .help("Dismiss this warning. The original file remains untouched.")
                }

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
            .padding(.top, 2)
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A modal sheet presenting full details for a damaged or unreadable record,
/// explaining why it couldn't be loaded and reassuring the user that the file
/// is untouched and can be restored from a backup.
struct DamagedRecordReviewSheet: View {
    let entry: UnreadableEntry
    let onDismissNotice: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.warn.color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.kind == .databaseRecord ? "Unreadable Database Record"
                         : entry.kind == .storedRecord ? "Damaged Record"
                         : entry.kind == .patientRecord ? "Damaged Patient Record" : "Damaged Session Record")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.text.color)
                    Text(entry.shortDescription)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.muted.color)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Explanation")
                    .eyebrowStyle()
                Text(entry.message)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("File Location")
                    .eyebrowStyle()
                HStack(spacing: 8) {
                    Text(entry.fileURL.path)
                        .font(Theme.Typography.caption.monospaced())
                        .foregroundStyle(Theme.text.color)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .themeField()
                    #if canImport(AppKit)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL])
                    }
                    .buttonStyle(.themed)
                    .controlSize(.small)
                    #endif
                }
            }

            HStack {
                Button("Dismiss Notice", action: onDismissNotice)
                    .buttonStyle(.themed)
                    .help("Dismiss this notice from the list. The original file remains untouched.")

                Spacer()

                Button("Done", action: onClose)
                    .buttonStyle(.themePrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.panel.color)
    }
}
