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
///
///   idle        Not recording · patient picker · Start recording
///   recording   chip + patient · timer · Mic / Call levels · Pause · Stop and save
///   paused      chip + patient · muted timer · note · Resume · Stop and save
///   ──────────
///   quiet rows  Show this session · Open Aletheia · Quit · engine status
struct RecordingMenuBar: View {
    @EnvironmentObject private var recorder: SessionRecorder
    @EnvironmentObject private var transcription: TranscriptionCoordinator
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var integrations: Integrations
    @EnvironmentObject private var appLock: AppLock
    @Environment(\.openWindow) private var openWindow
    @State private var engineState: EngineRunState = .loading
    /// The patient chosen in the picker; falls back to the first one when unset
    /// or when that patient is gone.
    @State private var selectedPatientID: UUID?
    /// Why the last Start didn't begin recording, shown under the button.
    @State private var startProblem: String?
    /// Ticked in the menu for a patient who hasn't been attested yet.
    /// Consent asked in place, for a patient whose next session needs it.
    @State private var consent = ConsentCapture()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if appLock.isLocked {
                Label(MenuBarPanel.Strings.locked, systemImage: "lock.fill")
                    .font(Theme.Typography.control)
                Button(MenuBarPanel.Strings.unlock) {
                    MainWindow.show(openWindow: openWindow)
                    appLock.requestUnlock()
                }
                .buttonStyle(.themePrimary)
            } else if let active = recorder.active {
                recordingControls(active)
            } else {
                startControls
            }
            if !appLock.isLocked {
                hairline
                quietRows
            }
        }
        .padding(16)
        .frame(width: 280)
        .background(Theme.panel.color)
        // Every time the menu is opened (this view is re-created) and every
        // 5s while it's open — cheap enough for the local-only health check
        // this reuses, and nothing here is data anyone would need faster.
        .liveStatusRefresh(every: 5) { _ in
            guard !appLock.isLocked else { return }
            engineState = await EngineStatusProbe.currentState(settings: settings, integrations: integrations)
        }
    }

    // MARK: Quiet rows

    /// Everything that isn't the recording control: kept below the divider as
    /// low-key rows in the design's quiet-button style.
    private var quietRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let active = recorder.active {
                Button("Show this session") {
                    MainWindow.show(openWindow: openWindow)
                    AppNavigator.shared.requestOpen(patientID: active.patientID)
                }
                .buttonStyle(MenuBarQuietRowStyle())
            }
            Button("Open Aletheia") { MainWindow.show(openWindow: openWindow) }
                .buttonStyle(MenuBarQuietRowStyle())
            Button("Quit Aletheia") { NSApp.terminate(nil) }
                .buttonStyle(MenuBarQuietRowStyle())
            engineStatusRow
                .padding(.horizontal, 10)
                .padding(.top, 6)
            if let status = transcription.statusLine {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(status)
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .padding(.horizontal, 10)
                .padding(.top, 4)
            }
        }
    }

    // MARK: Engine status

    /// Read-only line showing whether the local AI engine (the
    /// embedded llama.cpp runtime) is reachable and which model is active —
    /// reuses the same health-check seam as Settings/setup, just polled here
    /// on a slower cadence since the menu bar is glanced at, not stared at.
    private var engineStatusRow: some View {
        let presentation = EngineStatusPresentation.present(engineState)
        return Label(presentation.label, systemImage: presentation.symbolName)
            .font(Theme.Typography.caption)
            .foregroundStyle(presentation.tint.color)
    }

    private var hairline: some View {
        Rectangle().fill(Theme.line.color).frame(height: 1)
    }

    // MARK: Recording

    @ViewBuilder
    private func recordingControls(_ active: SessionRecorder.ActiveRecording) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if recorder.isPaused {
                Chip(MenuBarPanel.Strings.pausedChip, tone: .warn)
            } else {
                Chip(MenuBarPanel.Strings.recordingChip, tone: .recording, showsDot: true)
            }
            Spacer(minLength: 8)
            Text(MenuBarContentPolicy.patientLabel(
                name: active.patientName, showFullName: settings.notificationsShowPatientNames,
                isLocked: appLock.isLocked))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .lineLimit(1)
        }
        elapsedLabel

        if recorder.isPaused {
            Text("Nothing is being captured. Resume to continue the same session.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            MenuBarLevels(levels: recorder.levels)
        }

        HStack(spacing: 8) {
            if recorder.isPaused {
                Button { recorder.resume() } label: {
                    Label(MenuBarPanel.Strings.resume, systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.themePrimary)
                .help("Resume recording")
            } else {
                Button { recorder.pause() } label: {
                    Label(MenuBarPanel.Strings.pause, systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.themed)
                .help("Pause recording")
            }
            Button(role: .destructive) {
                Task { await recorder.stop() }
            } label: {
                Label(MenuBarPanel.Strings.stopAndSave, systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.themeRecording)
            .help("Stop recording and save this session")
        }
    }

    /// Live elapsed time. TimelineView drives the per-second refresh; the
    /// paused span is still counted as wall-clock, which is fine for a "how
    /// long has this been open" cue.
    private var elapsedLabel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(elapsedString(now: context.date))
                .font(.system(size: 44, weight: .regular, design: .serif).monospacedDigit())
                .foregroundStyle(recorder.isPaused ? Theme.muted.color : Theme.text.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityLabel("Elapsed \(elapsedString(now: context.date))")
        }
    }

    /// `HH:MM:SS`, as in the design.
    private func elapsedString(now: Date) -> String {
        let total = Int(max(0, recorder.elapsed(at: now)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    // MARK: Start

    @ViewBuilder
    private var startControls: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.muted.color).frame(width: 8, height: 8)
            Text(MenuBarPanel.Strings.notRecording)
                .font(Theme.Typography.control.weight(.semibold))
                .foregroundStyle(Theme.text.color)
        }
        .accessibilityElement(children: .combine)
        if appModel.patients.isEmpty {
            Text(MenuBarPanel.Strings.noPatients)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(MenuBarPanel.Strings.patientPicker).eyebrowStyle()
                let labels = MenuBarContentPolicy.pickerLabels(
                    appModel.patients.map { ($0.id, $0.name, $0.createdAt) },
                    showFullName: settings.notificationsShowPatientNames, isLocked: appLock.isLocked)
                Picker(MenuBarPanel.Strings.patientPicker, selection: patientSelection) {
                    ForEach(appModel.patients) { patient in
                        Text(labels[patient.id] ?? PatientLabel.blankFallback).tag(patient.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let patient = selectedPatient, appModel.needsRecordingConsent(patient: patient, session: nil) {
                consentFields
            }
            Button {
                if let patient = selectedPatient { Task { await start(for: patient) } }
            } label: {
                Label(MenuBarPanel.Strings.startRecording, systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.themePrimary)
            .controlSize(.large)
            .disabled(selectedPatient == nil || !MenuBarContentPolicy.canStartRecording(isLocked: appLock.isLocked, isStarting: recorder.isStarting)
                || RecordingConsent.menuBarProblem(needsConsent: selectedNeedsConsent, capture: consent) != nil)
            if let startProblem {
                Text(startProblem)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Records a new session. Make sure your client has consented first.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Who and how, then the confirmation: the consent sheet, in place.
    private var consentFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(RecordingConsent.sheetTitle).eyebrowStyle()
            Picker("Who consented", selection: $consent.party) {
                ForEach(ConsentParty.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            if consent.party.needsName {
                ThemeTextField(placeholder: "Name", text: $consent.name)
            }
            ThemeSegmentedControl(
                options: ConsentMethod.allCases.map { ThemeTab(value: $0, title: $0.title) },
                selection: $consent.method)
            Toggle(RecordingConsent.attestationText, isOn: $consent.confirmed)
                .toggleStyle(.checkbox)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.text.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectedNeedsConsent: Bool {
        selectedPatient.map { appModel.needsRecordingConsent(patient: $0, session: nil) } ?? false
    }

    private var selectedPatient: Patient? {
        appModel.patients.first { $0.id == selectedPatientID } ?? appModel.patients.first
    }

    private var patientSelection: Binding<UUID> {
        Binding(
            get: { selectedPatient?.id ?? UUID() },
            set: { selectedPatientID = $0; consent = ConsentCapture() }
        )
    }

    private func start(for patient: Patient) async {
        guard !appLock.isLocked else { return }
        // Taken now: after the awaits below, a system panel may be the key window.
        let panel = MainWindow.menuBarPanel()
        // Before creating a session, so a refused start leaves no empty one behind.
        guard !recorder.isBusy else { return }
        // The menu has no alert of its own, so a refusal reads in its problem line.
        appModel.refreshDiskEncryption()
        guard PHIEntryGate.allowsNewPHI(diskEncrypted: appModel.diskEncrypted) else {
            startProblem = PHIEntryGate.blockedMessage
            return
        }
        // Before creating a session, so a refused start leaves no empty one behind.
        if let refusal = recorder.startRefusal() {
            startProblem = refusal
            return
        }
        let needsConsent = appModel.needsRecordingConsent(patient: patient, session: nil)
        if let problem = RecordingConsent.menuBarProblem(needsConsent: needsConsent, capture: consent) {
            startProblem = problem
            return
        }
        guard let store = appModel.store,
              let session = appModel.startNewSession(for: patient) else {
            startProblem = "Couldn't create a session. Check the data folder in Settings."
            return
        }
        if needsConsent {
            // The panel has no When field: consent is given as Start is pressed.
            consent.consentedAt = Date()
            do {
                try appModel.recordConsent(consent, patient: patient, session: session)
                consent = ConsentCapture()
            } catch {
                startProblem = error.localizedDescription
                return
            }
        }
        startProblem = await recorder.start(
            micURL: store.micRecordingURL(for: patient, session: session),
            callURL: store.callRecordingURL(for: patient, session: session),
            context: .init(
                sessionID: session.id,
                patientID: patient.id,
                patientName: patient.name,
                patientSlug: patient.slug,
                sessionFolder: session.folderName
            ),
            protector: appModel.currentProtector
        )
        // Stay on the menu when it didn't start, so the reason is read here.
        guard startProblem == nil else { return }
        MainWindow.show(openWindow: openWindow, panel: panel)
        AppNavigator.shared.requestOpen(patientID: patient.id)
    }
}

/// The live Mic and Call input bars. Observes only `RecordingLevels`, so the
/// frequent level updates redraw these bars and nothing else.
private struct MenuBarLevels: View {
    @ObservedObject var levels: RecordingLevels

    var body: some View {
        VStack(spacing: 8) {
            row("Mic", accessibilityName: "Your microphone level", level: levels.mic, tint: Theme.accent.color)
            row("Call", accessibilityName: "Call audio level", level: levels.call, tint: Theme.callAudio.color)
        }
    }

    private func row(_ title: String, accessibilityName: String, level: Float, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .frame(width: 52, alignment: .leading)
            ThemeProgressBar(value: Double(level), tint: tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityName)
    }
}

/// The design's quiet button: no fill or border, muted text that brightens with
/// a hover wash under the pointer.
private struct MenuBarQuietRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietRow(configuration: configuration)
    }

    private struct QuietRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            let active = isHovered || configuration.isPressed
            configuration.label
                .font(Theme.Typography.control)
                .foregroundStyle(active ? Theme.text.color : Theme.muted.color)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background(active ? Theme.hover.color : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: active)
        }
    }
}

private extension EngineStatusTint {
    /// Running reads as the accent, starting/warning as the amber used for the
    /// call track, stopped as the recording red; unknown is muted. All have
    /// readable contrast on the panel in light, dark and Increase Contrast.
    var color: Color {
        switch self {
        case .green: return Theme.accent.color
        case .yellow: return Theme.callAudio.color
        case .red: return Theme.recording.color
        case .gray: return Theme.muted.color
        }
    }
}
