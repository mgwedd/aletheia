import AppKit
import SwiftUI

/// The Aletheia Doctor window: runs the health checks on demand, lists each
/// with a plain-language result and next step, and offers a PHI-safe "Copy
/// report". Nothing runs until this window is opened or Re-run is pressed.
struct DoctorView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations

    @State private var report: DoctorReport?
    @State private var isRunning = false
    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line.color).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let failure = appModel.databaseState.failure {
                        databaseProblemCard(failure)
                    }
                    if let report {
                        ForEach(report.grouped) { group in
                            section(group.category, group.checks)
                        }
                        Text("This report contains check names, statuses, counts and versions only — never patient names, session names or note text. Everything is checked on this Mac.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.muted.color)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking…").foregroundStyle(Theme.muted.color)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Theme.window.color)
        .task { await run() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if let report {
                statusIcon(report.overall).font(Theme.Typography.headline)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Aletheia Doctor")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.text.color)
                Text(report?.summary ?? "Checking your setup…")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
            }
            Spacer()
            if isRunning { ProgressView().controlSize(.small) }
            Button("Re-run") { Task { await run() } }
                .buttonStyle(.themed)
                .disabled(isRunning)
            Button(justCopied ? "Copied" : "Copy Report") { copyReport() }
                .buttonStyle(.themed)
                .disabled(report == nil)
        }
        .padding()
    }

    // MARK: - Rows

    @ViewBuilder
    private func databaseProblemCard(_ failure: DatabaseOpenFailure) -> some View {
        let folder = settings.dataRootURL
        let guidance = DatabaseFailureGuidance.guidance(for: failure, dataFolder: folder?.path)
        VStack(alignment: .leading, spacing: 8) {
            Label(guidance.headline, systemImage: "exclamationmark.octagon.fill")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.recording.color)
            DatabaseGuidanceView(guidance: guidance, failure: failure, dataFolder: folder)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.recordingTint.color, in: RoundedRectangle(cornerRadius: 8))
    }

    private func section(_ category: DoctorCategory, _ checks: [DoctorCheck]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(category.title)
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.text.color)
            ForEach(checks) { check in
                row(check)
                if check.id != checks.last?.id { Rectangle().fill(Theme.line.color).frame(height: 1) }
            }
        }
    }

    private func row(_ check: DoctorCheck) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(check.status)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.title)
                    .font(Theme.Typography.body.weight(.medium))
                    .foregroundStyle(Theme.text.color)
                Text(check.detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let next = check.nextStep {
                    Text("Next: \(next)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.text.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func statusIcon(_ status: DoctorStatus) -> some View {
        switch status {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent.color)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.callAudio.color)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.recording.color)
        }
    }

    // MARK: - Actions

    private func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let probes = LiveDoctorProbes.make(settings: settings, appModel: appModel, integrations: integrations)
        // The disk and SQLite probes are synchronous file I/O; keep them off the
        // main thread. The reused ToolHealth rows hop back to the main actor
        // themselves.
        report = await Task.detached(priority: .userInitiated) {
            await DoctorRunner(probes: probes).run()
        }.value
    }

    private func copyReport() {
        guard let report else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report.plainText(), forType: .string)
        justCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            justCopied = false
        }
    }
}
