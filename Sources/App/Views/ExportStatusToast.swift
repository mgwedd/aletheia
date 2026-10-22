import AppKit
import SwiftUI

/// Where a records export has got to, anchored to a corner of the main window so
/// it stays visible while the therapist works. Idle shows nothing.
struct ExportStatusToast: View {
    @ObservedObject var center: ExportJobCenter

    var body: some View {
        Group {
            switch center.state {
            case .idle:
                EmptyView()
            case let .running(fraction, label):
                running(fraction: fraction, label: label)
            case let .finished(url, outcome):
                finished(url: url, outcome: outcome)
            case let .failed(message):
                failed(message)
            }
        }
        .animation(.easeOut(duration: 0.15), value: center.state)
    }

    private func running(fraction: Double, label: String) -> some View {
        card {
            Text("Exporting records").font(Theme.Typography.control).foregroundStyle(Theme.text.color)
            ThemeProgressBar(value: fraction)
            HStack {
                Text(label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Cancel") { center.cancel() }
                    .buttonStyle(.themed)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Exporting records, \(Int((min(max(fraction, 0), 1) * 100).rounded())) percent. \(label)")
    }

    private func finished(url: URL, outcome: PatientArchiveWriter.Outcome) -> some View {
        card {
            Label("Export ready", systemImage: "checkmark.circle.fill")
                .font(Theme.Typography.control)
                .foregroundStyle(Theme.ok.color)
            Text(Self.summary(outcome))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
            ExportFileLink(url: url) { center.dismiss() }
            HStack {
                Spacer(minLength: 0)
                Button("Done") { center.dismiss() }
                    .buttonStyle(.themed)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    center.dismiss()
                }
                .buttonStyle(.themePrimary)
            }
            .controlSize(.small)
        }
        .onAppear { Self.announce("Export ready") }
    }

    private func failed(_ message: String) -> some View {
        card {
            Label("Export didn't finish", systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Typography.control)
                .foregroundStyle(Theme.warn.color)
            Text(message)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 0)
                Button("Dismiss") { center.dismiss() }
                    .buttonStyle(.themed)
                    .controlSize(.small)
            }
        }
        .onAppear { Self.announce("Export didn't finish") }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(14)
            .frame(width: 300, alignment: .leading)
            .themeCard()
    }

    /// "12 sessions, 31 files". The therapist is looking at their own data, so counts are fine here.
    static func summary(_ outcome: PatientArchiveWriter.Outcome) -> String {
        let sessions = outcome.sessionCount == 1 ? "1 session" : "\(outcome.sessionCount) sessions"
        let files = outcome.fileCount == 1 ? "1 file" : "\(outcome.fileCount) files"
        return "\(sessions), \(files) in a zip of text files."
    }

    private static func announce(_ text: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
