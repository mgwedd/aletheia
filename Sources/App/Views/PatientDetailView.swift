import SwiftUI

struct PatientDetailView: View {
    let patient: Patient
    /// Opens the profile editor (hosted by `RootView`, which the sidebar's
    /// context menu shares).
    let onEditProfile: () -> Void

    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations
    @EnvironmentObject private var transcription: TranscriptionCoordinator
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
            VStack(alignment: .leading, spacing: 12) {
                header

                PatientProfileCard(
                    patient: storedPatient,
                    showsMedications: showsMedications,
                    onEdit: onEditProfile
                )

                HStack {
                    Button {
                        showPatientChat = true
                    } label: {
                        Label("Ask About All Sessions", systemImage: "bubble.left.and.bubble.right")
                    }
                    .disabled(sessions.isEmpty)
                    Spacer()
                    Button {
                        exportHistory()
                    } label: {
                        Label("Export History", systemImage: "square.and.arrow.up")
                    }
                    .disabled(sessions.isEmpty)
                }

                Divider()

                HStack {
                    Text("Sessions").font(.headline)
                    Spacer()
                    Button {
                        newSession()
                    } label: {
                        Label("New Session", systemImage: "plus")
                    }
                }

                if !damagedSessions.isEmpty {
                    DamagedRecordsNotice(
                        title: damagedSessions.count == 1
                            ? "1 session couldn't be read"
                            : "\(damagedSessions.count) sessions couldn't be read",
                        entries: damagedSessions
                    )
                }

                List(sessions, selection: guardedSelection) { session in
                    SessionRow(session: session, isTranscribing: transcription.job(for: session.id) != nil).tag(session.id)
                }
                .listStyle(.inset)
                // Never let the list collapse to a sliver when the editors above
                // it claim the space; it takes whatever is left, at least 180pt.
                .frame(minHeight: 180, maxHeight: .infinity)
                .overlay {
                    if sessions.isEmpty {
                        ContentUnavailableView {
                            Label("No Sessions Yet", systemImage: "waveform")
                        } description: {
                            Text("Start a session to record, transcribe, and summarize it.")
                        } actions: {
                            Button("New Session") { newSession() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .padding()
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
        .onAppear { refresh() }
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

    /// The patient's name (click or the pencil to rename) with a one-line summary
    /// of their sessions.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(storedPatient.name)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(2)
                    .onTapGesture(perform: onEditProfile)
                Button(action: onEditProfile) {
                    Label("Edit Profile", systemImage: "pencil")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Edit name and profile")
            }
            Text(sessionSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sessionSummary: String {
        guard !sessions.isEmpty else { return "No sessions yet" }
        let count = sessions.count == 1 ? "1 session" : "\(sessions.count) sessions"
        guard let latest = sessions.map(\.date).max() else { return count }
        return "\(count) · last \(latest.formatted(date: .abbreviated, time: .omitted))"
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
    var isTranscribing = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(Self.formatter.string(from: session.date)).font(.body)
                HStack(spacing: 6) {
                    if session.hasRecording { Label("Recording", systemImage: "waveform").labelStyle(.iconOnly) }
                    if session.hasTranscript { Label("Transcript", systemImage: "text.alignleft").labelStyle(.iconOnly) }
                    if session.hasSummary { Label("Summary", systemImage: "doc.text").labelStyle(.iconOnly) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if isTranscribing {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .help("Transcribing…")
            }
        }
        .padding(.vertical, 2)
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
