import AletheiaCore
import SwiftUI
import AppKit

/// The menu-bar panel for controlling session recording without hunting through
/// the main window. Because recording isn't automatic — the therapist decides
/// when the client has consented and the session has started — this makes the
/// Start / Pause / Stop controls reachable from anywhere, with the call window
/// in front.
///
/// Uses the shared app-level `SessionRecorder`, so what it shows and controls is
/// the same recording the session view drives.
struct RecordingMenuBar: View {
    @EnvironmentObject private var recorder: SessionRecorder
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var integrations: Integrations
    @State private var engineState: EngineRunState = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            engineStatusRow
            Divider()
            if let active = recorder.active {
                recordingControls(active)
            } else {
                startControls
            }
            Divider()
            Button("Open Aletheia") { NSApp.activate(ignoringOtherApps: true) }
            Button("Quit Aletheia") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 280)
        // Every time the menu is opened (this view is re-created) and every
        // 5s while it's open — cheap enough for the local-only health check
        // this reuses, and nothing here is data anyone would need faster.
        .liveStatusRefresh(every: 5) { _ in
            engineState = await EngineStatusProbe.currentState(settings: settings, integrations: integrations)
        }
    }

    // MARK: Engine status

    /// Read-only line showing whether the local AI engine (Ollama, or the
    /// embedded llama.cpp runtime) is reachable and which model is active —
    /// reuses the same health-check seam as Settings/setup, just polled here
    /// on a slower cadence since the menu bar is glanced at, not stared at.
    private var engineStatusRow: some View {
        let presentation = EngineStatusPresentation.present(engineState)
        return Label(presentation.label, systemImage: presentation.symbolName)
            .font(.caption)
            .foregroundStyle(presentation.tint.color)
    }

    // MARK: Recording

    @ViewBuilder
    private func recordingControls(_ active: SessionRecorder.ActiveRecording) -> some View {
        HStack(spacing: 8) {
            Image(systemName: recorder.isPaused ? "pause.circle.fill" : "record.circle.fill")
                .foregroundStyle(recorder.isPaused ? .orange : .red)
                .symbolEffect(.pulse, options: recorder.isPaused ? .nonRepeating : .repeating)
            VStack(alignment: .leading, spacing: 1) {
                Text(recorder.isPaused ? "Paused" : "Recording")
                    .font(.headline)
                Text(active.patientName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        elapsedLabel

        HStack {
            if recorder.isPaused {
                Button { recorder.resume() } label: {
                    Label("Resume", systemImage: "play.fill")
                }
            } else {
                Button { recorder.pause() } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
            }
            Button(role: .destructive) {
                Task { await recorder.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
        }
        .buttonStyle(.borderedProminent)

        Button("Show this session") {
            NSApp.activate(ignoringOtherApps: true)
            AppNavigator.shared.requestOpen(patientID: active.patientID)
        }
        .font(.callout)
    }

    /// Live elapsed time. TimelineView drives the per-second refresh; the paused
    /// span is still counted as wall-clock, which is fine for a "how long has
    /// this been open" cue.
    private var elapsedLabel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(elapsedString(now: context.date))
                .font(.system(.title3, design: .monospaced))
                .monospacedDigit()
        }
    }

    private func elapsedString(now: Date) -> String {
        guard let started = recorder.startedAt else { return "00:00" }
        let total = Int(max(0, now.timeIntervalSince(started)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    // MARK: Start

    @ViewBuilder
    private var startControls: some View {
        Text("Start a recording")
            .font(.headline)
        if appModel.patients.isEmpty {
            Text("Add a patient in the main window first.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text("Records a new session. Make sure your client has consented first.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(appModel.patients) { patient in
                Button {
                    Task { await start(for: patient) }
                } label: {
                    Label(patient.name, systemImage: "record.circle")
                }
            }
        }
    }

    private func start(for patient: Patient) async {
        guard let store = appModel.store,
              let session = appModel.startNewSession(for: patient) else { return }
        await recorder.start(
            micURL: store.micRecordingURL(for: patient, session: session),
            callURL: store.callRecordingURL(for: patient, session: session),
            context: .init(
                patientID: patient.id,
                patientName: patient.name,
                patientSlug: patient.slug,
                sessionFolder: session.folderName
            ),
            protector: appModel.currentProtector
        )
        NSApp.activate(ignoringOtherApps: true)
        AppNavigator.shared.requestOpen(patientID: patient.id)
    }
}

private extension EngineStatusTint {
    /// Matches the green/yellow/red convention `SettingsView.statusIcon`
    /// already uses for `ToolHealthCheck.Status`, so this reads as the same
    /// status language elsewhere in the app.
    var color: Color {
        switch self {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        case .gray: return .secondary
        }
    }
}
