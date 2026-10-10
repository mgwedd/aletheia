import AppKit
import SwiftUI

/// The Aletheia Doctor window: runs the health checks on demand, lists each
/// with a plain-language result and next step, and offers a PHI-safe "Copy
/// report". Nothing runs until this window is opened or "Run checks again" is pressed.
struct DoctorView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations

    @State private var report: DoctorReport?
    @State private var isRunning = false
    @State private var justCopied = false
    @State private var showOnlyIssues = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let report { metaRow(report) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let failure = appModel.databaseState.failure {
                        databaseProblemCard(failure)
                    }
                    if let report {
                        let groups = report.grouped(onlyIssues: showOnlyIssues)
                        ForEach(groups) { group in
                            section(group.category, group.checks)
                        }
                        if groups.isEmpty { noIssuesCard(report) }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking…").foregroundStyle(Theme.muted.color)
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Theme.window.color)
        .task { await run() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(report?.headline ?? "Checking your setup…")
                    .font(.system(size: 30, weight: .regular, design: .serif))
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let report {
                    Text(report.explanation)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.muted.color)
                        .lineSpacing(3)
                        .frame(maxWidth: 520, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if isRunning { ProgressView().controlSize(.small) }
                Button("Run checks again") { Task { await run() } }
                    .buttonStyle(.themed)
                    .disabled(isRunning)
                Button(justCopied ? "Copied" : "Copy report") { copyReport() }
                    .buttonStyle(.themePrimary)
                    .disabled(report == nil)
            }
            .fixedSize()
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    private func metaRow(_ report: DoctorReport) -> some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text("Last run \(report.lastRunDescription(now: context.date)). \(report.checkCountDescription).")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
            }
            Spacer()
            HStack(spacing: 10) {
                Toggle("Show only issues", isOn: $showOnlyIssues)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.accent.color)
                Text("Show only issues")
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.text.color)
                    .onTapGesture { showOnlyIssues.toggle() }
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock")
                .font(.system(size: 12))
                .accessibilityHidden(true)
            Text("This report contains check names, statuses, counts and versions only — never patient names, session names or note text. Everything is checked on this Mac.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.muted.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.vertical, 14)
        .background(Theme.sidebar.color)
        .themeDivider(.top)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeBanner(.danger)
    }

    private func section(_ category: DoctorCategory, _ checks: [DoctorCheck]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(category.title)
                .eyebrowStyle()
            VStack(spacing: 0) {
                ForEach(checks) { check in
                    row(check)
                    if check.id != checks.last?.id {
                        Rectangle().fill(Theme.line.color).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themeCard()
        }
    }

    private func noIssuesCard(_ report: DoctorReport) -> some View {
        Text(report.overall == .ok ? "No issues. All \(report.checkCountDescription) passed." : "No issues to show.")
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.muted.color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .themeCard()
    }

    private func row(_ check: DoctorCheck) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Chip(check.status.label, tone: check.status.chipTone)
                .frame(width: 72)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(Theme.Typography.body.weight(.medium))
                    .foregroundStyle(Theme.text.color)
                Text(check.detail)
                    .font(Theme.Typography.control.weight(.regular))
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let next = check.nextStep {
                    Text("Next: \(next)")
                        .font(Theme.Typography.control.weight(.regular))
                        .foregroundStyle(Theme.text.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
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

private extension DoctorStatus {
    /// The chip colour for this result.
    var chipTone: Chip.Tone {
        switch self {
        case .ok: return .ok
        case .warning: return .warn
        case .failed: return .recording
        }
    }
}
