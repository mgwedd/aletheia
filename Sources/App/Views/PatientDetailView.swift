import SwiftUI
import UniformTypeIdentifiers

struct PatientDetailView: View {
    let patient: Patient
    /// Opens the profile editor (hosted by `RootView`, which the sidebar's
    /// context menu shares).
    let onEditProfile: (ProfileField) -> Void

    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var integrations: Integrations
    @EnvironmentObject private var transcription: TranscriptionCoordinator
    /// Shared with the session view and the menu bar, to mark the row that is
    /// being recorded right now.
    @EnvironmentObject private var recorder: SessionRecorder
    /// Carries a session chosen in global search to this patient's view.
    @ObservedObject private var navigator = AppNavigator.shared
    @State private var sessions: [SessionRecord] = []
    @State private var pendingExport: ExportConfirmation?
    /// Session folders whose `session.json` couldn't be read (left untouched).
    @State private var damagedSessions: [UnreadableEntry] = []
    private var visibleDamagedSessions: [UnreadableEntry] {
        damagedSessions.filter { !settings.isDamagedRecordDismissed(id: $0.id) }
    }
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
    @State private var sessionInitialTab: SessionTab = .transcript
    @State private var sessionInitialNoteFormat: ProgressNoteFormat?
    @State private var sessionInitialShowingMyNotes = false
    @State private var sessionInitialFocusedCommentID: String?
    /// The search match to flash, and the session it is in: only that session
    /// is opened at it, not one picked from the list afterwards.
    @State private var sessionInitialSearchFocus: (sessionID: UUID, focus: SearchMatchFocus)?
    @State private var sessionNavigationToken = 0
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var exports: ExportJobCenter
    @State private var errorMessage: String?
    @State private var showNothingToExport = false
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
                            psychotherapyExportButton
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            askAllButton
                            exportButton
                            psychotherapyExportButton
                        }
                    }
                    SummaryStatusRow(scheduler: integrations.digestScheduler, patientID: patient.id)

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

                        if !visibleDamagedSessions.isEmpty {
                            DamagedRecordsNotice(
                                title: visibleDamagedSessions.count == 1
                                    ? "1 session couldn't be read"
                                    : "\(visibleDamagedSessions.count) sessions couldn't be read",
                                entries: visibleDamagedSessions,
                                onDismiss: { entry in
                                    settings.dismissDamagedRecord(id: entry.id)
                                }
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
                    SessionDetailView(
                        patient: patient,
                        session: selectedSession,
                        onSessionUpdated: refresh,
                        editGuard: editGuard,
                        initialTab: sessionInitialTab,
                        initialFocusedCommentID: sessionInitialFocusedCommentID,
                        initialSearchFocus: sessionInitialSearchFocus?.sessionID == selectedSession.id ? sessionInitialSearchFocus?.focus : nil,
                        initialNoteFormat: sessionInitialNoteFormat,
                        initialShowingMyNotes: sessionInitialShowingMyNotes,
                        navigationToken: sessionNavigationToken
                    )
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
            appModel.access.viewedPatient(patient.id)
            refresh()
            openPendingSession()
            integrations.digestScheduler.patientOpened(patient)
        }
        .onChange(of: navigator.pendingSession) { _, _ in openPendingSession() }
        // A transcription finishing changes which sessions have a transcript or
        // recording, even when it isn't the session currently on screen.
        .onChange(of: transcription.outcomes) { _, _ in refresh() }
        .exportConfirmation($pendingExport, settings: settings)
        .dismissOnLock { pendingExport = nil }
        .alert(PsychotherapyExport.nothingToExportTitle, isPresented: $showNothingToExport) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(PsychotherapyExport.nothingToExportMessage)
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
            openWindow(id: PatientChatWindow.windowID, value: patient.id)
        } label: {
            Label("Ask about this patient", systemImage: "bubble.left.and.bubble.right")
        }
        .buttonStyle(.themed)
        .disabled(sessions.isEmpty)
    }

    private var exportButton: some View {
        Button {
            exportRecords()
        } label: {
            Label("Export all records", systemImage: "square.and.arrow.up.on.square")
        }
        .buttonStyle(.themed)
        .disabled(sessions.isEmpty || exports.isRunning)
        .help(exports.isRunning
            ? "An export is already running"
            : "Save every transcript and progress note as a zip of text files. Psychotherapy notes are not included. It's prepared in the background and you'll be told when it's ready.")
    }

    private var psychotherapyExportButton: some View {
        Button {
            guard let store = appModel.store, !exports.isRunning else { return }
            guard PsychotherapyExport.hasAnythingToExport(store: store, sessions: sessions) else {
                showNothingToExport = true
                return
            }
            pendingExport = ExportConfirmation(
                patientName: patient.name, noun: "session", count: sessions.count, fileType: "zip",
                scope: .psychotherapy
            ) { exportPsychotherapyNotes() }
        } label: {
            Label("Export psychotherapy notes…", systemImage: "lock.doc")
        }
        .buttonStyle(.themed)
        .disabled(sessions.isEmpty || exports.isRunning)
        .help("Save your psychotherapy notes and private comments on their own, apart from the clinical record. You'll confirm you have authorization first.")
    }

    /// The session list. Selection is by id and goes through `guardedSelection`,
    /// so the unsaved-transcript prompt still guards every switch.
    private var sessionList: some View {
        List(sessions, selection: guardedSelection) { session in
            SessionRow(
                session: session,
                isSelected: session.id == selectedSessionID,
                isTranscribing: transcription.job(for: session.id) != nil,
                isQueued: transcription.isWaiting(session.id),
                isRecording: isRecording(session)
            )
            .tag(session.id)
            .accessibilityIdentifier("session-row")
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
            if SessionListEmptyState.isShown(sessionCount: sessions.count) {
                ContentUnavailableView {
                    Label(SessionListEmptyState.title, systemImage: "waveform")
                } description: {
                    Text(SessionListEmptyState.detail)
                } actions: {
                    Button(SessionListEmptyState.newSessionButton) { newSession() }
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
                .onTapGesture { onEditProfile(.name) }
            Button { onEditProfile(.name) } label: {
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
        PatientSessionText.summary(count: sessions.count)
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

    /// Selects the session global search or Spotlight asked for, if it belongs
    /// to this patient. Goes through `requestSelection`, so unsaved transcript edits
    /// are still guarded.
    private func openPendingSession() {
        guard let pending = navigator.pendingSession, pending.patientID == patient.id else { return }
        navigator.pendingSession = nil
        let target = sessions.first { session in
            if let id = pending.sessionID, session.id == id { return true }
            if let folder = pending.sessionFolderName, session.folderName == folder { return true }
            return false
        }
        guard let target else { return }
        sessionInitialTab = pending.initialTab ?? .transcript
        sessionInitialNoteFormat = pending.initialNoteFormat
        sessionInitialShowingMyNotes = pending.initialShowingMyNotes
        sessionInitialFocusedCommentID = pending.initialFocusedCommentID
        sessionInitialSearchFocus = pending.initialSearchFocus.map { (sessionID: target.id, focus: $0) }
        sessionNavigationToken += 1
        if selectedSessionID != target.id {
            requestSelection(target.id)
        }
    }

    private func newSession() {
        guard appModel.authorizeNewPHI(), let store = appModel.store else { return }
        do {
            let session = try store.createSession(for: patient)
            refresh()
            requestSelection(session.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Asks where to save, then builds the zip in the background. A whole patient's
    /// history is far too long for one PDF, so this is text files in a zip; PDF, Word
    /// and Markdown are per session and per note.
    /// Writes the psychotherapy notes and private comments as their own zip,
    /// after the authorization confirmation. Never part of "Export all records".
    private func exportPsychotherapyNotes() {
        guard let store = appModel.store, !exports.isRunning else { return }
        guard let destination = FileSaver.chooseDestination(
            suggestedName: FileSaver.exportFileName(forPatientNamed: patient.name, "Psychotherapy notes") + ".zip",
            type: .zip
        ) else { return }
        let patient = patient
        let sessions = sessions
        let model = appModel
        let detail = AuditDetail.exportedPsychotherapyNotes
        exports.start(destination: destination, onFinished: { _ in
            model.recordAudit(.recordExported, subjectID: patient.id.uuidString, detail: detail)
        }, onFailed: {
            model.recordAudit(.exportFailed, subjectID: patient.id.uuidString, detail: detail)
        }) { progress, isCancelled in
            try PsychotherapyExport.write(
                patientName: patient.name,
                sessionCount: sessions.count,
                loadEntry: { PsychotherapyExport.load(store: store, session: sessions[$0]) },
                to: destination,
                authorized: true,
                progress: progress,
                isCancelled: isCancelled
            )
        }
    }

    private func exportRecords() {
        guard appModel.store != nil, !exports.isRunning else { return }
        pendingExport = ExportConfirmation(
            patientName: patient.name, noun: "session", count: sessions.count, fileType: "zip", scope: .patientWide
        ) { saveRecords() }
    }

    private func saveRecords() {
        guard let store = appModel.store, !exports.isRunning else { return }
        guard let destination = FileSaver.chooseDestination(
            suggestedName: FileSaver.exportFileName(forPatientNamed: patient.name, "Records") + ".zip",
            type: .zip
        ) else { return }
        let patient = patient
        let sessions = sessions
        let model = appModel
        exports.start(
            patientName: patient.name,
            background: patient.notes,
            sessionCount: sessions.count,
            load: { try ArchiveLoader.load(store: store, patient: patient, session: sessions[$0]) },
            destination: destination
        ) { outcome in
            model.recordAudit(
                .recordExported, subjectID: patient.id.uuidString,
                detail: .exportedPatientRecords(sessions: outcome.sessionCount)
            )
        } onFailed: {
            model.recordAudit(.exportFailed, subjectID: patient.id.uuidString, detail: "Patient records, zip")
        }
    }
}

private struct SessionRow: View {
    let session: SessionRecord
    var isSelected = false
    var isTranscribing = false
    var isQueued = false
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
        if isQueued { return "Waiting to transcribe" }
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
