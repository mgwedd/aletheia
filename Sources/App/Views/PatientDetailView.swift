import SwiftUI

struct PatientDetailView: View {
    let patient: Patient
    /// Opens the profile editor (hosted by `RootView`, which the sidebar's
    /// context menu shares).
    let onEditProfile: () -> Void

    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations
    @EnvironmentObject private var transcription: TranscriptionCoordinator
    /// Shared with the session view and the menu bar, to mark the row that is
    /// being recorded right now.
    @EnvironmentObject private var recorder: SessionRecorder
    /// Carries a session chosen in global search to this patient's view.
    @ObservedObject private var navigator = AppNavigator.shared
    @State private var sessions: [SessionRecord] = []
    /// Session folders whose `session.json` couldn't be read (left untouched).
    @State private var damagedSessions: [UnreadableEntry] = []
    /// Selection is tracked by id, not by `SessionRecord`: the record is
    /// Hashable over every field (hasTranscript, hasSummary, ...), so after a
    /// refresh() a stored copy would no longer equal the row's tag and the
    /// highlight would be lost.
    @State private var selectedSessionID: UUID?
    /// Asks the open session whether it has unsaved transcript edits before the
    /// selection moves to another session.
    @StateObject private var editGuard = UnsavedTranscriptGuard()
    /// The selection the user asked for while edits were unsaved, held while the
    /// Save / Discard / Cancel prompt is up.
    @State private var pendingSelection: SessionSelection?
    @State private var showUnsavedPrompt = false
    @State private var showPatientChat = false
    @State private var errorMessage: String?
    /// The selected session, resolved against the current listing so a session
    /// that has dropped out of it can't leave a dangling selection.
    private var selectedSession: SessionRecord? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    /// The patient as currently stored. `patient` is a snapshot handed in by the
    /// parent and can lag behind a save, so change-detection guards compare
    /// against this instead (falling back to the snapshot if it's not listed).
    private var storedPatient: Patient {
        appModel.patients.first { $0.id == patient.id } ?? patient
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .frame(minHeight: 52)

                VStack(alignment: .leading, spacing: 22) {
                    PatientProfileCard(
                        patient: storedPatient,
                        showsMedications: showsMedications,
                        onEdit: onEditProfile
                    )

                    // Side by side when they fit, stacked when the column is narrow.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            askAllButton
                            exportButton
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            askAllButton
                            exportButton
                        }
                    }

                    Rectangle()
                        .fill(Theme.line.color)
                        .frame(height: 1)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Sessions").eyebrowStyle()
                            Spacer()
                            Button {
                                newSession()
                            } label: {
                                Label("New session", systemImage: "plus")
                            }
                            .buttonStyle(.themed)
                        }

                        if !damagedSessions.isEmpty {
                            DamagedRecordsNotice(
                                title: damagedSessions.count == 1
                                    ? "1 session couldn't be read"
                                    : "\(damagedSessions.count) sessions couldn't be read",
                                entries: damagedSessions
                            )
                        }

                        sessionList
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .background(Theme.panel.color)
            // Capped so the list column can't swallow the split when the right
            // pane is momentarily small, and pinned to the top so a short column
            // isn't centred in a tall window.
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 600, maxHeight: .infinity, alignment: .top)

            // One frame for both states: swapping a session for the placeholder
            // must not change the pane's size, or the split view re-lays out.
            Group {
                if let selectedSession {
                    SessionDetailView(patient: patient, session: selectedSession, onSessionUpdated: refresh, editGuard: editGuard)
                        .id(selectedSession.id)
                } else {
                    ContentUnavailableView(
                        "Select a Session",
                        systemImage: "waveform",
                        description: Text("Choose a session on the left, or start a new one.")
                    )
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(storedPatient.name)
        .onAppear {
            refresh()
            openPendingSession()
        }
        .onChange(of: navigator.pendingSession) { _, _ in openPendingSession() }
        // A transcription finishing changes which sessions have a transcript or
        // recording, even when it isn't the session currently on screen.
        .onChange(of: transcription.outcomes) { _, _ in refresh() }
        .sheet(isPresented: $showPatientChat) {
            PatientChatSheet(patient: patient)
                .environmentObject(appModel)
                .environmentObject(integrations)
                .frame(minWidth: 560, minHeight: 500)
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Save your transcript edits?", isPresented: $showUnsavedPrompt, titleVisibility: .visible) {
            Button("Save") {
                if editGuard.save() { applyPendingSelection() } else { pendingSelection = nil }
            }
            Button("Discard Edits", role: .destructive) {
                editGuard.discard()
                applyPendingSelection()
            }
            Button("Cancel", role: .cancel) { pendingSelection = nil }
        } message: {
            Text("This session's transcript has changes you haven't saved.")
        }
    }

    private struct SessionSelection {
        let id: UUID
    }

    /// The session list's selection, routed through `requestSelection` so a
    /// click on another session can't silently drop unsaved transcript edits.
    /// A click on the list's empty space reports `nil`; that is ignored so it
    /// doesn't close the open session (selection only clears when the session
    /// itself disappears, see `refresh`).
    private var guardedSelection: Binding<UUID?> {
        Binding(
            get: { selectedSessionID },
            set: { newValue in
                guard let newValue else { return }
                requestSelection(newValue)
            }
        )
    }

    private func requestSelection(_ id: UUID) {
        guard id != selectedSessionID else { return }
        if editGuard.hasUnsavedEdits {
            pendingSelection = SessionSelection(id: id)
            showUnsavedPrompt = true
        } else {
            selectedSessionID = id
        }
    }

    private func applyPendingSelection() {
        if let pendingSelection { selectedSessionID = pendingSelection.id }
        pendingSelection = nil
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var showsMedications: Bool {
        appModel.featureRegistry.contains(id: PatientMedicationsFeatureModule.id)
    }

    private var askAllButton: some View {
        Button {
            showPatientChat = true
        } label: {
            Label("Ask about all sessions", systemImage: "bubble.left.and.bubble.right")
        }
        .buttonStyle(.themed)
        .disabled(sessions.isEmpty)
    }

    private var exportButton: some View {
        Button {
            exportHistory()
        } label: {
            Label("Export history", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.themed)
        .disabled(sessions.isEmpty)
    }

    /// The session list. Selection is by id and goes through `guardedSelection`,
    /// so the unsaved-transcript prompt still guards every switch.
    private var sessionList: some View {
        List(sessions, selection: guardedSelection) { session in
            SessionRow(
                session: session,
                isSelected: session.id == selectedSessionID,
                isTranscribing: transcription.job(for: session.id) != nil,
                isRecording: isRecording(session)
            )
            .tag(session.id)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Never let the list collapse to a sliver when the editors above
        // it claim the space; it takes whatever is left, at least 180pt.
        .frame(minHeight: 180, maxHeight: .infinity)
        // Rows carry their own 8pt inset, so the list reaches 8pt past the
        // column's gutter and the selected fill lines up with the fields above.
        .padding(.horizontal, -8)
        .overlay {
            if sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Sessions Yet", systemImage: "waveform")
                } description: {
                    Text("Start a session to record, transcribe, and summarize it.")
                } actions: {
                    Button("New session") { newSession() }
                        .buttonStyle(.themePrimary)
                }
            }
        }
    }

    /// Whether the app-wide recorder is recording into this session's folder.
    private func isRecording(_ session: SessionRecord) -> Bool {
        recorder.isRecording
            && recorder.active?.patientSlug == patient.slug
            && recorder.active?.sessionFolder == session.folderName
    }

    /// The patient's name (click or the pencil to rename) with a count of their
    /// sessions.
    private var header: some View {
        HStack(spacing: 6) {
            Text(storedPatient.name)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.text.color)
                .lineLimit(2)
                .onTapGesture(perform: onEditProfile)
            Button(action: onEditProfile) {
                Label("Edit Profile", systemImage: "pencil")
            }
            .buttonStyle(.themeIcon)
            .controlSize(.small)
            .help("Edit name and profile")
            Spacer(minLength: 8)
            Chip(sessionSummary)
        }
    }

    private var sessionSummary: String {
        switch sessions.count {
        case 0: return "No sessions"
        case 1: return "1 session"
        default: return "\(sessions.count) sessions"
        }
    }

    private func refresh() {
        guard let store = appModel.store else { return }
        do {
            let listing = try store.sessionListing(for: patient)
            sessions = listing.sessions
            damagedSessions = listing.unreadable
            // Drop a selection whose session is no longer listed.
            if let id = selectedSessionID, !listing.sessions.contains(where: { $0.id == id }) {
                selectedSessionID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Selects the session global search asked for, if it belongs to this
    /// patient. Goes through `requestSelection`, so unsaved transcript edits
    /// are still guarded.
    private func openPendingSession() {
        guard let pending = navigator.pendingSession, pending.patientID == patient.id else { return }
        navigator.pendingSession = nil
        if sessions.contains(where: { $0.id == pending.sessionID }) {
            requestSelection(pending.sessionID)
        }
    }

    private func newSession() {
        guard let store = appModel.store else { return }
        do {
            let session = try store.createSession(for: patient)
            refresh()
            requestSelection(session.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportHistory() {
        guard let store = appModel.store else { return }
        let markdown = store.exportPatientHistoryMarkdown(patient: patient)
        let name = FileSaver.fileName(patient.name, "Session History") + ".md"
        FileSaver.saveText(markdown, suggestedName: name)
    }
}

private struct SessionRow: View {
    let session: SessionRecord
    var isSelected = false
    var isTranscribing = false
    var isRecording = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private var detail: String {
        if isRecording { return "Recording in progress" }
        if isTranscribing { return "Transcribing…" }
        var parts = [Self.timeFormatter.string(from: session.date)]
        if session.hasRecording { parts.append("Audio") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.dateFormatter.string(from: session.date))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(1)
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isTranscribing {
                ProgressView()
                    .controlSize(.small)
                    .help("Transcribing…")
            }
            HStack(spacing: 4) {
                if isRecording { Chip("Recording", tone: .recording, showsDot: true) }
                if session.hasTranscript { Chip("Transcript") }
                if session.hasSummary { Chip("Note") }
            }
        }
        .accessibilityElement(children: .combine)
        .themeListRow(isSelected: isSelected, surface: Theme.panel)
    }
}

private struct PatientChatSheet: View {
    let patient: Patient
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PatientChatView(patient: patient) { dismiss() }
            .environmentObject(appModel)
            .environmentObject(integrations)
    }
}
