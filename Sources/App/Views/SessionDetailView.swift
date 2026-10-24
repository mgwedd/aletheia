import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The tabs in the session detail. Comments no longer have their own tab —
/// they live in a margin rail beside the transcript (Google-Docs style), so
/// the passage and its comments are read together.
enum SessionTab: Hashable {
    case transcript, notes, ask
}

/// What the Notes tab is showing: the therapist's own free-form notes, or the
/// AI-drafted note in one of the documentation formats.
enum NotesPane: Hashable, Identifiable {
    case mine
    case format(ProgressNoteFormat)

    var id: Self { self }

    /// Picker order: the drafted formats (Summary first), then the therapist's own.
    static let all: [NotesPane] = ProgressNoteFormat.allCases.map(NotesPane.format) + [.mine]

    var label: String {
        switch self {
        case .mine: return "My Notes"
        case .format(let format): return format.shortName
        }
    }
}

/// Live progress (stage, elapsed time, tokens) while the session's digest is
/// being built in the background, or a short failure with a retry.
private struct DigestStatusLine: View {
    @ObservedObject var builder: DigestBuilder
    let sessionID: UUID
    let retry: () -> Void

    var body: some View {
        if let progress = builder.progress[sessionID] {
            VStack(alignment: .leading, spacing: 6) {
                AIProgressView(progress: DigestBuilder.statusProgress(progress))
                if let steps = progress.steps {
                    ThemeProgressBar(value: steps.fraction)
                        .frame(maxWidth: 240)
                }
            }
            .padding([.horizontal, .top], 20)
        } else if let failure = builder.failures[sessionID] {
            HStack(spacing: 8) {
                Text(failure)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                Button("Retry", action: retry)
                    .buttonStyle(ThemeButtonStyle())
                    .controlSize(.small)
            }
            .padding([.horizontal, .top], 20)
        }
    }
}

/// The note pane's progress: the shared status line, led by "Generating SOAP
/// note", over a bar that never moves backwards.
private struct NoteProgressRow: View {
    let title: String
    let progress: AIRunProgress
    let speed: ModelSpeed?
    /// Owned by the session view and replaced per run: the row is rebuilt
    /// mid-run (when the first text arrives), which would reset a `@State` here.
    let highWater: ProgressHighWater

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 6) {
                AIStatusLineView(text: NoteProgress.statusLine(title: title, progress, now: context.date))
                ThemeProgressBar(value: highWater.clamp(NoteProgress.fraction(progress, now: context.date, speed: speed)))
                    .frame(maxWidth: 240)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct SessionDetailView: View {
    let patient: Patient
    let session: SessionRecord
    /// Called after recording, transcribing, or summarizing changes what's
    /// on disk for this session, so the sessions list (visible at the same
    /// time in the split view) can refresh its "has recording/transcript/
    /// summary" badges without the therapist needing to click away and back.
    var onSessionUpdated: () -> Void = {}
    /// Lets the session list ask this view about unsaved transcript edits before
    /// switching to another session.
    var editGuard: UnsavedTranscriptGuard? = nil
    var initialTab: SessionTab = .transcript
    var initialFocusedCommentID: String? = nil
    /// A search match to scroll to and flash on `initialTab` (transcript or note).
    var initialSearchFocus: SearchMatchFocus? = nil
    var initialNoteFormat: ProgressNoteFormat? = nil
    var initialShowingMyNotes: Bool = false
    var navigationToken: Int = 0

    init(
        patient: Patient,
        session: SessionRecord,
        onSessionUpdated: @escaping () -> Void = {},
        editGuard: UnsavedTranscriptGuard? = nil,
        initialTab: SessionTab = .transcript,
        initialFocusedCommentID: String? = nil,
        initialSearchFocus: SearchMatchFocus? = nil,
        initialNoteFormat: ProgressNoteFormat? = nil,
        initialShowingMyNotes: Bool = false,
        navigationToken: Int = 0
    ) {
        self.patient = patient
        self.session = session
        self.onSessionUpdated = onSessionUpdated
        self.editGuard = editGuard
        self.initialTab = initialTab
        self.initialFocusedCommentID = initialFocusedCommentID
        self.initialSearchFocus = initialSearchFocus
        self.initialNoteFormat = initialNoteFormat
        self.initialShowingMyNotes = initialShowingMyNotes
        self.navigationToken = navigationToken
        self._selectedTab = State(initialValue: initialTab)
        self._showingMyNotes = State(initialValue: initialShowingMyNotes)
        self._focusedCommentID = State(initialValue: initialFocusedCommentID)
        self._focusToken = State(initialValue: initialFocusedCommentID != nil ? 1 : 0)
    }

    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations
    @EnvironmentObject private var settings: AppSettings
    // Shared with the menu-bar control (injected at app level) so both drive the
    // same recording. "Recording" in this view means *this* session specifically.
    @EnvironmentObject private var recorder: SessionRecorder
    // App-level so a transcription survives leaving this screen.
    @EnvironmentObject private var transcription: TranscriptionCoordinator

    /// The transcript as saved on disk. Generated notes, chat and staleness all
    /// key off this, never off the draft.
    @State private var transcriptText: String = ""
    /// What the transcript view shows and edits. Differs from `transcriptText`
    /// until the user presses Save (or Discard).
    @State private var transcriptDraft = ""
    /// A transcript file exists (possibly empty), so the editor stays available
    /// after everything is deleted instead of reverting to the empty state.
    @State private var hasTranscript = false
    /// Set when the transcript exists but couldn't be read. Editing is then off:
    /// saving would overwrite a file we never managed to open.
    @State private var transcriptReadError: String?
    /// The draft was restored from an earlier visit; don't let the "saved text
    /// changed" sync below replace it.
    @State private var restoredDraft = false
    @State private var showDiscardConfirm = false
    /// Fingerprint of the transcript the displayed format's note was generated
    /// from, if one was recorded. See `NoteFreshness`.
    @State private var noteFingerprint: String?
    /// What the displayed format's note was written from, when it was not the
    /// whole transcript (a long session).
    @State private var noteCoverage: String?
    /// What the last session chat answer was written from when the session was too long to send whole.
    @State private var sessionChatCoverage: String?
    /// Stop was pressed and the stopped note's job may still be unwinding.
    @State private var noteStopping = false
    /// The format of the note being generated, for its progress line.
    @State private var generatingFormat: ProgressNoteFormat = .default
    /// Keeps that progress bar from moving backwards; a new one per run.
    @State private var noteHighWater = ProgressHighWater()
    /// Waits for a stopped note's job to unwind before starting the next one.
    @State private var noteWaiter: Task<Void, Never>?
    @State private var summaryText: String = ""
    @State private var chatMessages: [ChatMessage] = []
    @State private var sessionNote: String = ""
    // Editing the generated note (selected format only; Save/Cancel, no autosave).
    @State private var isEditingNote = false
    @State private var noteDraft = ""
    @State private var confirmRegenerate = false
    @State private var hasPreviousNote = false
    @State private var noteCopied = false
    @State private var editingInstructions = false
    /// The note text as last read from / written to the store. `load()` assigns
    /// `sessionNote` programmatically, which fires `onChange`; comparing against
    /// this keeps that echo (and any no-op change) from being saved back.
    @State private var persistedSessionNote: String = ""
    @State private var comments: [SessionComment] = []
    /// The passage currently selected in the transcript view (empty = just a
    /// caret), driving the floating comment button.
    @State private var transcriptSelection = ""
    /// Where that selection sits in the transcript (UTF-16), nil for a caret.
    @State private var transcriptSelectionRange: NSRange?
    /// The first line of that selection in the transcript pane, where the
    /// floating comment button goes (nil for a caret).
    @State private var transcriptSelectionRect: CGRect?
    /// Which side of the transcript / comments split the reader folded away.
    @State private var splitCollapsed: TranscriptSplit.Side?
    /// The passage and its start offset, frozen when the comment is begun so
    /// the composer sheet opening (or the selection changing) can't move what
    /// the comment gets anchored to.
    @State private var pendingQuote = ""
    @State private var pendingQuoteStart: Int?
    @State private var showInlineComposer = false
    /// "0:31": the time stamp of the line the pending comment is on.
    @State private var pendingTimeLabel: String?
    /// Where the pending passage's last line sits in the transcript pane, as
    /// reported by the text view (nil until it has been placed).
    @State private var composerAnchor: CGRect?
    @State private var composerHeight: CGFloat = 230
    @State private var inlineCommentBody = ""
    @State private var selectedTab: SessionTab = .transcript
    /// Whether the Notes tab shows the therapist's own notes instead of a drafted note.
    @State private var showingMyNotes = false
    /// The comment currently in focus — drives the two-way highlight between a
    /// transcript passage and its card in the margin rail. Set by clicking
    /// either side.
    @State private var focusedCommentID: String?
    /// Bumped on every focus request so the scroll-and-flash is an event, not a
    /// state: re-clicking the already-focused card still jumps to its passage.
    @State private var focusToken = 0
    /// Bumped with `focusToken` for comment focus only, so opening the
    /// transcript at a search match doesn't also reveal the comments rail.
    @State private var commentRevealToken = 0
    /// The search match the transcript scrolls to and flashes, when no comment
    /// is focused (see `transcriptFocus`).
    @State private var searchMatchRange: NSRange?
    /// The search match to scroll to and flash in the drafted note, and its
    /// request token (bumped per opened hit); the last token shown, so it shows
    /// once per request; and the rendered block currently flashed.
    @State private var noteSearchFocus: SearchMatchFocus?
    @State private var noteFocusToken = 0
    @State private var lastNoteFocusToken: Int?
    @State private var flashedNoteBlock: Int?
    /// Set when the last transcription came back blank and the recording was
    /// kept (see `AudioRetentionPolicy.decision`); shown inline, not as an alert.
    @State private var noSpeechNotice: String?
    @State private var isChatSending = false
    @StateObject private var chatRunner = ChatStreamRunner()
    @StateObject private var noteRunner = ChatStreamRunner()
    @State private var errorMessage: String?
    /// How the last export ended, shown until dismissed.
    @State private var exportResult: SaveOutcome?
    /// Set when note generation or a chat answer failed because the local AI
    /// engine is down; `engineRetries` re-runs whatever failed after the fix.
    @State private var engineIncident: AIEngineIncident?
    @State private var engineRetries = PendingRetries<EngineRetryKind, () -> Void>()
    @State private var confirmationMessage: String?
    @State private var showScheduleSheet = false
    @State private var scheduleStart = Date()
    @State private var scheduleDurationMinutes = SessionEventBuilder.defaultDurationMinutes
    @State private var scheduleRecurrence: EventRecurrence = .never
    @State private var scheduleExportICS = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private static let tabs: [ThemeTab<SessionTab>] = [
        ThemeTab(value: .transcript, title: "Transcript"),
        ThemeTab(value: .notes, title: "Notes"),
        ThemeTab(value: .ask, title: "Ask"),
    ]

    //   header      date · time/duration chip
    //   action bar  record / pause / timer | transcribe | export
    //   tab bar     Transcript  Notes  Ask
    //   content     the selected tab, on the panel surface
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            actionBar
            UnderlineTabBar(tabs: Self.tabs, selection: $selectedTab)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.window.color)
                .themeDivider(.bottom)
            // Above the tab content, so progress shows on every tab.
            if let job = transcription.job(for: session.id) {
                TranscriptionProgressView(job: job, sessionDate: session.date) {
                    transcription.cancel(sessionID: session.id)
                }
            } else if isQueued {
                TranscriptionQueuedView {
                    transcription.cancel(sessionID: session.id)
                }
            }
            // Notes and Ask need the local AI engine; say so before a request fails.
            if selectedTab != .transcript {
                AIEngineBanner()
            }
            Group {
                switch selectedTab {
                case .transcript: transcriptTab
                case .notes: notesTab
                case .ask: chatTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.panel.color)
        }
        .navigationTitle(Self.dateFormatter.string(from: session.date))
        .background(Theme.window.color)
        .selectablePatientText()
        .onAppear {
            if initialShowingMyNotes {
                showingMyNotes = true
            } else if let initialNoteFormat {
                showingMyNotes = false
                settings.progressNoteFormat = initialNoteFormat
            }
            selectedTab = initialTab

            load()

            if let initialFocusedCommentID {
                focusComment(initialFocusedCommentID)
            }
            applySearchFocus()
            ensureDigest()
            // Load the model now so the first note or question skips the load.
            integrations.makeAssistant().warmUp(model: integrations.activeModelName)
            // A transcription that finished while this screen was away.
            consumeTranscriptionOutcome()
        }
        .onChange(of: navigationToken) { _, _ in
            applyNavigationTarget()
        }
        .onDisappear {
            // Navigation that couldn't ask first (another patient, a search hit):
            // keep the unsaved edits for the next time this session opens.
            UnsavedTranscriptDrafts.stash(transcriptDraft, saved: transcriptText, for: session.id)
            editGuard?.detach()
            // A note must not start after the user has left.
            noteWaiter?.cancel()
            noteWaiter = nil
        }
        .onChange(of: transcriptText) { old, new in
            if !new.isEmpty { hasTranscript = true; transcriptReadError = nil }
            // A new saved transcript (e.g. a fresh transcription) replaces the
            // draft only if there were no unsaved edits to lose.
            if restoredDraft { restoredDraft = false } else if transcriptDraft == old { transcriptDraft = new }
        }
        .onChange(of: transcription.outcomes[session.id]) { _, outcome in
            if outcome != nil { consumeTranscriptionOutcome() }
        }
        // Each format keeps its own note, so the pane follows the picker. Here
        // rather than on the Notes pane so a change made while another tab (or
        // My Notes) is showing still swaps the note.
        .onChange(of: settings.progressNoteFormat) { _, newFormat in
            isEditingNote = false
            summaryText = savedNote(for: newFormat)
            noteFingerprint = savedFingerprint(for: newFormat)
            noteCoverage = savedCoverage(for: newFormat)
            refreshHasPreviousNote()
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .aiEngineAlert($engineIncident, retry: {
            for retry in engineRetries.takeAll() { retry() }
        }, discard: {
            engineRetries.clear()
        })
        .alert("Done", isPresented: Binding(get: { confirmationMessage != nil }, set: { if !$0 { confirmationMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(confirmationMessage ?? "")
        }
        .sheet(isPresented: $showScheduleSheet) { scheduleSheet }
        .exportResultAlert($exportResult)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(Self.dateFormatter.string(from: session.date))
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.text.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            if isRecordingThisSession {
                Chip(recorder.isPaused ? "Paused" : "Recording", tone: .recording, showsDot: true)
            } else {
                Chip(headerDetail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(Theme.window.color)
    }

    /// "2:14 PM · 1m 24s": when the session started and, once there is a
    /// transcript, roughly how long it ran (its last time stamp).
    private var headerDetail: String {
        let time = Self.timeFormatter.string(from: session.date)
        guard let seconds = TranscriptTimeline.lastSeconds(in: transcriptText), seconds > 0 else { return time }
        return "\(time) · \(TranscriptTimeline.durationLabel(seconds))"
    }

    /// The session's actions on one strip. Full labels when the window is wide
    /// enough, icons (each with a tooltip) when it isn't, so nothing truncates.
    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            actionControls.labelStyle(.titleAndIcon)
            actionControls.labelStyle(.iconOnly)
        }
        .buttonStyle(.themed)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(Theme.panel.color)
        .themeDivider(.top)
        .themeDivider(.bottom)
    }

    private var actionControls: some View {
        HStack(spacing: 10) {
            if isRecordingThisSession {
                Button {
                    Task { await stopRecording() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.fill")
                }
                .buttonStyle(.themeRecording)
                .help("Stop recording this session")
                if recorder.isPaused {
                    Button { recorder.resume() } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .help("Resume recording")
                } else {
                    Button { recorder.pause() } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .help("Pause recording")
                }
                recordingTimer
            } else if offersRecord {
                if recorder.isRecording {
                    // A different session is recording (via the menu bar); don't let
                    // this view start a second one or stop the other by surprise.
                    Label("Recording another session", systemImage: "record.circle")
                        .font(Theme.Typography.control)
                        .foregroundStyle(Theme.muted.color)
                        .help("Stop the current recording from the menu bar first")
                } else {
                    Button {
                        Task { await startRecording() }
                    } label: {
                        Label("Record Session", systemImage: "record.circle")
                    }
                    .help(recordBlocker ?? "Record this session's audio")
                    .disabled(recordBlocker != nil)
                }
            }

            if offersRecord || isRecordingThisSession, offersTranscribe {
                Rectangle()
                    .fill(Theme.line.color)
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, 4)
            }

            // The label stays put; a spinner beside it shows work is under way
            // (the progress itself is the band under the tab bar).
            if offersTranscribe {
                Button {
                    noSpeechNotice = nil
                    transcription.start(patient: patient, session: session)
                } label: {
                    Label("Transcribe", systemImage: "waveform")
                }
                .help(transcribeBlocker ?? (transcription.isBusy
                      ? "Another session is being transcribed. This one will start when it finishes"
                      : "Transcribe the recording"))
                .disabled(transcribeBlocker != nil)
                if isTranscribing {
                    ProgressView().controlSize(.small)
                }
            }

            if SessionActionPolicy.offersExport(hasTranscript: !transcriptText.isEmpty, hasSummary: !summaryText.isEmpty) {
                ExportButton(help: "Save this session's note and transcript as a PDF, Word or Markdown file") {
                    exportSession(as: $0)
                }
            }

            // "Remind Me" / "Schedule Next…" belong to the `.dev`-tier EventKit
            // scheduling module; absent from production/preview builds. See
            // `EventKitSchedulingFeatureModule`.
            if appModel.featureRegistry.contains(id: EventKitSchedulingFeatureModule.id) {
                Menu {
                    ForEach(ReminderLeadTime.allCases) { leadTime in
                        Button(leadTime.displayName) { Task { await scheduleReminder(leadTime) } }
                    }
                } label: {
                    Label("Remind Me", systemImage: "bell")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a follow-up reminder to your Reminders app")

                Button {
                    scheduleStart = SessionEventBuilder.suggestedStart()
                    scheduleDurationMinutes = SessionEventBuilder.defaultDurationMinutes
                    scheduleRecurrence = .never
                    scheduleExportICS = false
                    showScheduleSheet = true
                } label: {
                    Label("Schedule Next…", systemImage: "calendar.badge.plus")
                }
                .help("Add the next session to your Calendar")
            }
        }
    }

    /// Red dot and elapsed time while this session records; the dot holds
    /// still while paused.
    private var recordingTimer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.recording.color)
                    .frame(width: 8, height: 8)
                    .opacity(recorder.isPaused ? 0.5 : 1)
                Text(recordingElapsed(at: context.date))
                    .font(Theme.Typography.control.monospacedDigit())
                    .foregroundStyle(Theme.recording.color)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(recorder.isPaused ? "Paused" : "Recording, \(recordingElapsed(at: context.date))")
        }
        .padding(.leading, 4)
    }

    /// This session is recording and has no transcript yet: the pane is the
    /// clock, large enough to read from across the room.
    private var recordingPanel: some View {
        VStack(spacing: 14) {
            Chip(recorder.isPaused ? "Paused" : "Recording", tone: .recording, showsDot: true)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(recordingElapsed(at: context.date))
                    .font(Theme.Typography.timer)
                    .foregroundStyle(recorder.isPaused ? Theme.muted.color : Theme.text.color)
                    .accessibilityLabel("Elapsed \(recordingElapsed(at: context.date))")
            }
            InputLevelMeters(levels: recorder.levels, isPaused: recorder.isPaused)
            if let problem = recorder.callAudioProblem {
                callAudioNotice("Only your microphone is being recorded. \(problem)")
            } else if recorder.callAudioSilent, !recorder.isPaused {
                callAudioNotice("No call audio detected. Only your microphone is being recorded. If the other person is speaking, make sure the call plays through this Mac, and that Aletheia is allowed under Screen & System Audio Recording.")
            }
            if settings.debugDiagnosticsEnabled {
                CallAudioDebugView(recorder: recorder)
            }
            Text(recorder.isPaused
                 ? "Paused. Nothing is being recorded until you resume."
                 : "Stop when the session ends, then transcribe.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.muted.color)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: recorder.isPaused)
    }

    private func callAudioNotice(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.muted.color)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 440, alignment: .leading)
            .accessibilityElement(children: .combine)
    }

    private var noTranscriptPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 26))
                .foregroundStyle(Theme.muted.color)
            Text("No transcript yet")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.text.color)
            Text(hasAnyRecording
                 ? "Transcribe the recording to see it here."
                 : "Record the session, then transcribe it.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.muted.color)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Recorded time so far; the clock holds still while paused.
    private func recordingElapsed(at now: Date) -> String {
        TranscriptTimeline.format(Int(recorder.elapsed(at: now)))
    }

    private func scheduleReminder(_ leadTime: ReminderLeadTime) async {
        let draft = SessionReminderBuilder.draft(
            sessionDate: session.date,
            leadTime: leadTime
        )
        do {
            try await integrations.makeReminderScheduler().schedule(draft)
            confirmationMessage = "Reminder set for \(leadTime.displayName.lowercased()) at 9:00 AM."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleEvent() async {
        let draft = SessionEventBuilder.draft(
            start: scheduleStart,
            durationMinutes: scheduleDurationMinutes,
            recurrence: scheduleRecurrence
        )
        var icsSaved = false
        if scheduleExportICS {
            let icsText = ICSExporter.generate(for: draft)
            let dateStr = draft.startDate.formatted(date: .abbreviated, time: .omitted)
            let suggestedName = FileSaver.fileName(patient.name, "Session", dateStr) + ".ics"
            icsSaved = FileSaver.saveICS(icsText, suggestedName: suggestedName)
        }
        do {
            try await integrations.makeCalendarScheduler().schedule(draft)
            showScheduleSheet = false
            if scheduleExportICS && icsSaved {
                confirmationMessage = "Added “\(draft.title)” to your Calendar and saved .ics file."
            } else {
                confirmationMessage = "Added “\(draft.title)” to your Calendar."
            }
        } catch {
            showScheduleSheet = false
            if scheduleExportICS && icsSaved {
                confirmationMessage = "Saved .ics file. Could not add to Calendar: \(error.localizedDescription)"
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var scheduleSheet: some View {
        ScheduleNextSessionSheet(
            patientName: patient.name,
            lastSessionDate: session.date,
            start: $scheduleStart,
            durationMinutes: $scheduleDurationMinutes,
            recurrence: $scheduleRecurrence,
            exportICS: $scheduleExportICS,
            onCancel: { showScheduleSheet = false },
            onSchedule: { Task { await scheduleEvent() } }
        )
    }

    private func exportSession(as format: ExportFormat) {
        guard let store = appModel.store else { return }
        let document = ExportDocument(markdown: store.exportSessionMarkdown(patient: patient, session: session))
        let base = FileSaver.fileName(patient.name, String(session.folderName.prefix(10)))
        let outcome = ExportRenderer.save(document, as: format, baseName: base)
        if case .saved = outcome {
            appModel.recordAudit(.recordExported, subjectID: session.id.uuidString, detail: "Session, \(format.title)")
        } else if case .failed = outcome {
            appModel.recordAudit(.exportFailed, subjectID: session.id.uuidString, detail: "Session, \(format.title)")
        }
        exportResult = outcome.shown
    }

    /// Saves the note on screen in `format`, after the usual save panel.
    private func exportNote(as format: ExportFormat) {
        let noteFormat = settings.progressNoteFormat.shortName
        let dateStr = String(session.folderName.prefix(10))
        let document = ExportDocument(
            title: patient.name,
            subtitle: "\(noteFormat) · \(Self.dateFormatter.string(from: session.date))",
            markdown: summaryText
        )
        let base = FileSaver.fileName(patient.name, dateStr, noteFormat)
        let outcome = ExportRenderer.save(document, as: format, baseName: base)
        if case .saved = outcome {
            appModel.recordAudit(.recordExported, subjectID: session.id.uuidString, detail: "Note \(noteFormat), \(format.title)")
        } else if case .failed = outcome {
            appModel.recordAudit(.exportFailed, subjectID: session.id.uuidString, detail: "Note \(noteFormat), \(format.title)")
        }
        exportResult = outcome.shown
    }

    private var hasAnyRecording: Bool {
        guard let store = appModel.store else { return false }
        let mic = store.micRecordingURL(for: patient, session: session)
        let call = store.callRecordingURL(for: patient, session: session)
        return FileManager.default.fileExists(atPath: mic.path) || FileManager.default.fileExists(atPath: call.path)
    }

    private var transcriptTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            DigestStatusLine(builder: integrations.digests, sessionID: session.id, retry: {
                integrations.digestScheduler.retry(patient: patient, session: session)
            })
            if let notice = noSpeechNotice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Theme.muted.color)
                    Text(notice)
                        .foregroundStyle(Theme.text.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Dismiss") { noSpeechNotice = nil }
                        .buttonStyle(.themed)
                        .controlSize(.small)
                }
                .font(Theme.Typography.body)
                .padding(12)
                .background(Theme.callout.color, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.line.color))
                .padding([.horizontal, .top], 20)
            }
            if transcriptText.isEmpty && transcriptDraft.isEmpty && !hasTranscript {
                // While transcribing, the progress band above the tabs says it all.
                if isRecordingThisSession {
                    recordingPanel
                } else if !isTranscribing {
                    noTranscriptPlaceholder
                }
            } else {
                if let readError = transcriptReadError {
                    Label("This transcript couldn't be read, so editing is turned off to avoid overwriting it. \(readError)", systemImage: "lock")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.text.color)
                        .padding([.horizontal, .top], 20)
                }
                if TranscriptEditBar.showsEditControls(isDirty: transcriptIsDirty) {
                    HStack(spacing: 10) {
                        Spacer(minLength: 12)
                        if let note = TranscriptEditBar.statusNote(isDirty: transcriptIsDirty) {
                            Text(note)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.muted.color)
                                .lineLimit(1)
                        }
                        Button("Discard") { showDiscardConfirm = true }
                            .help("Throw away your unsaved edits")
                        Button("Save") { saveTranscriptDraft() }
                            .disabled(transcriptReadError != nil)
                            .shortcut(AppHotkey.saveEdits, help: "Save your edits to the transcript")
                    }
                    .buttonStyle(.themed)
                    .padding(.horizontal, 20)
                    .frame(height: 52)
                    .themeDivider(.bottom)
                }
                // Google-Docs layout: the transcript on the left, its comments in
                // a margin rail on the right, shown once there are comments and
                // sized by a draggable divider. Only *unresolved* comments carry
                // a highlight in the text; the rail keeps resolved ones tucked
                // away. The view edits the draft, and highlights follow it.
                TranscriptSplitView(
                    hasComments: !comments.isEmpty,
                    commentCount: comments.filter { !$0.resolved }.count,
                    ratio: $settings.transcriptSplitRatio,
                    collapsed: $splitCollapsed,
                    revealToken: commentRevealToken
                ) {
                    TranscriptTextView(
                        text: $transcriptDraft,
                        isEditable: transcriptReadError == nil,
                        comments: activeAnchors,
                        selection: $transcriptSelection,
                        selectionRange: $transcriptSelectionRange,
                        onOpenComment: openComment,
                        focus: transcriptFocus,
                        focusToken: focusToken,
                        composingRange: composingRange,
                        onComposingRectChange: { composerAnchor = $0 },
                        onSelectionRectChange: { transcriptSelectionRect = $0 },
                        callAudioName: Prompts.clientFirstName(patient.name)
                    )
                    // The comment composer sits on the transcript, just under the
                    // passage being commented on; the comment button floats at
                    // the selection.
                    .overlay { composerOverlay }
                    .overlay { commentButtonOverlay }
                } comments: {
                    CommentsRailView(
                        comments: comments,
                        focusedCommentID: $focusedCommentID,
                        unplacedIDs: TranscriptHighlighter.unplacedIDs(in: transcriptDraft, comments: activeAnchors),
                        focusToken: focusToken,
                        onFocus: focusComment,
                        onResolve: resolveComment,
                        onDelete: deleteComment,
                        onEdit: editComment
                    )
                    // The cards focus their comment on click; selectable text
                    // would take those clicks.
                    .textSelection(.disabled)
                }
            }
        }
        .confirmationDialog("Discard your unsaved edits?", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Discard Edits", role: .destructive) { discardTranscriptEdits() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("The transcript goes back to the last saved version.")
        }
        // The composer is tied to the saved transcript's offsets, so new text
        // (a fresh transcription) or unsaved edits close it.
        .onChange(of: transcriptText) { _, _ in showInlineComposer = false }
        .onChange(of: transcriptIsDirty) { _, dirty in if dirty { showInlineComposer = false } }
    }

    // Space around the composer card: it lines up with the transcript's text
    // column on the left and keeps the same gutter as the text on the right.
    private static let composerLeading: CGFloat = 88
    private static let composerTrailing: CGFloat = 24
    private static let composerMargin: CGFloat = 8
    private static let composerGap: CGFloat = 6

    /// The passage being commented on, as a range in the transcript.
    private var composingRange: NSRange? {
        guard showInlineComposer, let start = pendingQuoteStart else { return nil }
        let length = (pendingQuote as NSString).length
        return length > 0 ? NSRange(location: start, length: length) : nil
    }

    /// The inline composer: a card directly under the line holding the passage
    /// (above it when there is no room below, pinned inside the pane when the
    /// passage has scrolled away). The quoted text is fixed; you just write the
    /// note.
    @ViewBuilder
    private var composerOverlay: some View {
        if showInlineComposer {
            GeometryReader { proxy in
                InlineCommentComposerCard(
                    timeLabel: pendingTimeLabel,
                    quote: pendingQuote,
                    text: $inlineCommentBody,
                    onCancel: { showInlineComposer = false },
                    onSave: saveInlineComment
                )
                .frame(width: max(300, proxy.size.width - Self.composerLeading - Self.composerTrailing))
                .background(
                    GeometryReader { card in
                        Color.clear.preference(key: ComposerHeightKey.self, value: card.size.height)
                    }
                )
                // Hidden for the instant before the text view has placed the
                // passage, so the card doesn't flash at the top and jump.
                .opacity(composerAnchor == nil && composingRange != nil ? 0 : 1)
                .offset(x: Self.composerLeading, y: composerY(in: proxy.size.height))
            }
            .onPreferenceChange(ComposerHeightKey.self) { composerHeight = $0 }
        }
    }

    /// The comment button, floating just above the first line of the selected
    /// passage (below it when there is no room above). Shown only for a saved
    /// transcript, since a comment is pinned to saved text.
    @ViewBuilder
    private var commentButtonOverlay: some View {
        let hasSelection = !transcriptSelection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if CommentButtonPlacement.isVisible(
            hasSelection: hasSelection,
            isDirty: transcriptIsDirty,
            isComposing: showInlineComposer,
            isReadable: transcriptReadError == nil
        ), let anchor = transcriptSelectionRect {
            GeometryReader { proxy in
                if let origin = CommentButtonPlacement.origin(anchor: anchor, in: proxy.size) {
                    Button {
                        beginInlineComment()
                    } label: {
                        Label("Comment", systemImage: "text.bubble")
                    }
                    .buttonStyle(.themed)
                    .keyboardShortcut("m", modifiers: [.command, .option])
                    .help("Comment on the selected passage (\u{2325}\u{2318}M)")
                    .frame(width: CommentButtonPlacement.size.width, height: CommentButtonPlacement.size.height)
                    .offset(x: origin.x, y: origin.y)
                }
            }
        }
    }

    /// Top edge for the composer card: below the passage's last line if it fits,
    /// else above it, else pinned to the bottom of the pane.
    private func composerY(in paneHeight: CGFloat) -> CGFloat {
        let margin = Self.composerMargin
        let gap = Self.composerGap
        guard let anchor = composerAnchor else { return margin }
        let below = anchor.maxY + gap
        if below + composerHeight <= paneHeight - margin { return max(margin, below) }
        let above = anchor.minY - gap - composerHeight
        if above >= margin { return above }
        return max(margin, paneHeight - composerHeight - margin)
    }

    /// The unresolved comments as the highlighter sees them: id, quote, and the
    /// offset the quote started at (nil for comments from before positions were
    /// stored). Resolved comments carry no highlight.
    private var activeAnchors: [TranscriptHighlighter.Anchor] {
        comments.filter { !$0.resolved }.map { (id: $0.id, quote: $0.quotedText, start: $0.quoteStart) }
    }

    private func beginInlineComment() {
        // Freeze the quote and where it sits now. The start offset is of the
        // whitespace-trimmed quote (what gets stored), so a selection that
        // swept up a trailing newline still anchors on the right character.
        if let range = transcriptSelectionRange,
           let trimmed = TranscriptHighlighter.trimmed(range, in: transcriptText) {
            pendingQuote = (transcriptText as NSString).substring(with: trimmed)
            pendingQuoteStart = trimmed.location
        } else {
            pendingQuote = transcriptSelection.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingQuoteStart = nil
        }
        pendingTimeLabel = anchorSeconds(quote: pendingQuote, start: pendingQuoteStart).map { TranscriptTimeline.format($0) }
        inlineCommentBody = ""
        composerAnchor = nil
        showInlineComposer = true
    }

    /// The time stamp (seconds) of the line a quote sits on: from the exact
    /// offset when we know where it was, since searching for the quote text
    /// would land on its first occurrence.
    private func anchorSeconds(quote: String, start: Int?) -> Int? {
        if let start {
            return TranscriptTimeline.seconds(atOffset: start, in: transcriptText)
        }
        return TranscriptTimeline.seconds(forQuote: quote, in: transcriptText)
    }

    private func saveInlineComment() {
        guard let commentStore = appModel.commentStore else { return }
        let quote = pendingQuote
        let body = inlineCommentBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty, !body.isEmpty else { return }
        let anchorSecs = anchorSeconds(quote: quote, start: pendingQuoteStart)
        let created = appModel.addComment(
            sessionID: session.id,
            quotedText: quote,
            body: body,
            anchorSeconds: anchorSecs.map { Double($0) },
            quoteStart: pendingQuoteStart
        )
        comments = commentStore.comments(sessionID: session.id)
        // Keep the composer (and the typed comment) open when the save failed.
        guard let created else { return }
        showInlineComposer = false
        // Bring the new card into view in the rail.
        focusComment(created.id)
    }

    /// Requests focus on a comment: highlights its card, scrolls the card into
    /// view in the rail, and scrolls-and-flashes its passage in the transcript.
    /// Bumping the token makes each request an event, so asking for the
    /// already-focused comment again (after scrolling away) works too.
    private func focusComment(_ id: String) {
        focusedCommentID = id
        searchMatchRange = nil
        focusToken += 1
        commentRevealToken += 1
    }

    /// What the transcript scrolls to and flashes: the focused comment's
    /// passage, else the search match it was opened at.
    private var transcriptFocus: TranscriptFocus? {
        if let focusedCommentID { return .comment(focusedCommentID) }
        return searchMatchRange.map { .range($0) }
    }

    /// Opens at the search match this session was opened for: flashes it in
    /// the transcript, or asks the drafted note to scroll to it.
    private func applySearchFocus() {
        guard let initialSearchFocus else { return }
        switch initialTab {
        case .transcript:
            guard let range = initialSearchFocus.transcriptRange(in: transcriptDraft) else { return }
            focusedCommentID = nil
            searchMatchRange = range
            focusToken += 1
        case .notes:
            noteSearchFocus = initialSearchFocus
            noteFocusToken += 1
        case .ask:
            break
        }
    }

    /// Scrolls the drafted note to the block holding the search match and
    /// flashes it, once per request. Runs when the note appears and when a new
    /// request comes in while it is shown.
    private func showNoteSearchFocus(_ proxy: ScrollViewProxy) async {
        guard let noteSearchFocus,
              SearchMatchFocus.isNewRequest(token: noteFocusToken, lastHandledToken: lastNoteFocusToken) else { return }
        lastNoteFocusToken = noteFocusToken
        let blocks = MarkdownParser.parse(MarkdownTextStyle.note.prepared(summaryText))
        guard let block = noteSearchFocus.noteBlock(in: blocks, note: summaryText) else { return }
        // Let the note lay out before scrolling to one of its blocks.
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.snappy) { proxy.scrollTo(block, anchor: .center) }
        flashedNoteBlock = block
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        withAnimation(.easeOut(duration: 0.3)) {
            if flashedNoteBlock == block { flashedNoteBlock = nil }
        }
    }

    /// Clicking a highlighted passage focuses its card in the margin rail (and
    /// scrolls it into view) — no tab change, since the rail is right there.
    private func openComment(_ id: String) {
        focusComment(id)
    }

    /// Applies navigation requested externally (such as a search hit or deep link).
    private func applyNavigationTarget() {
        if initialShowingMyNotes {
            showingMyNotes = true
        } else if let initialNoteFormat {
            showingMyNotes = false
            settings.progressNoteFormat = initialNoteFormat
            summaryText = savedNote(for: initialNoteFormat)
            noteFingerprint = savedFingerprint(for: initialNoteFormat)
            noteCoverage = savedCoverage(for: initialNoteFormat)
            refreshHasPreviousNote()
        }
        selectedTab = initialTab
        if let initialFocusedCommentID {
            focusComment(initialFocusedCommentID)
        }
        applySearchFocus()
    }

    private func resolveComment(_ comment: SessionComment, _ resolved: Bool) {
        guard let commentStore = appModel.commentStore else { return }
        appModel.setCommentResolved(id: comment.id, resolved: resolved)
        comments = commentStore.comments(sessionID: session.id)
        // A resolved comment loses its highlight; don't keep focusing it.
        if resolved, focusedCommentID == comment.id { focusedCommentID = nil }
    }

    /// True when the draft differs from the saved transcript.
    private var transcriptIsDirty: Bool { transcriptDraft != transcriptText }

    /// Writes the draft as the transcript. On failure the draft is kept as it is
    /// and the error is shown; nothing is lost. Returns whether it was saved.
    @discardableResult
    private func saveTranscriptDraft() -> Bool {
        guard transcriptReadError == nil else { return false }
        guard let store = appModel.store else { return false }
        let text = transcriptDraft
        do {
            try store.saveTranscript(text, for: patient, session: session)
        } catch {
            errorMessage = "Couldn't save the transcript. Your edits are still here and nothing was lost. \(error.localizedDescription)"
            return false
        }
        transcriptText = text
        hasTranscript = true
        integrations.digestScheduler.transcriptSaved(patient: patient, session: session)
        onSessionUpdated()
        return true
    }

    private func discardTranscriptEdits() {
        transcriptDraft = transcriptText
    }

    private var myNotesView: some View {
        VStack(alignment: .leading, spacing: 8) {
            RichNoteEditor(
                markdown: $sessionNote,
                placeholder: "Jot things down during or after the session…",
                fonts: .sans,
                minHeight: 160,
                fills: true,
                label: "My notes"
            )
            .padding([.horizontal, .bottom], 20)
            .onChange(of: sessionNote) { _, newValue in
                guard newValue != persistedSessionNote else { return }
                persistedSessionNote = newValue
                appModel.saveNote(sessionID: session.id, text: newValue)
            }
        }
    }

    /// The Notes tab: one picker across the drafted formats and the therapist's
    /// own notes. Switching is locked while a note is generating or being edited.
    private var notesTab: some View {
        let locked = noteRunner.isStreaming || noteRunner.isQueued || isEditingNote
        return VStack(alignment: .leading, spacing: 14) {
            ThemeSegmentedControl(
                options: NotesPane.all.map { ThemeTab(value: $0, title: $0.label) },
                selection: notesPaneBinding,
                sizing: .fitted
            )
            .disabled(locked)
            .opacity(locked ? 0.55 : 1)
            .accessibilityLabel("Note")
            .hoverTip(showingMyNotes ? HelpTips.myNotes : nil)
            .padding([.horizontal, .top], 20)

            if showingMyNotes {
                myNotesView
            } else {
                generatedNoteView
            }
        }
    }

    private var notesPaneBinding: Binding<NotesPane> {
        Binding(
            get: { showingMyNotes ? .mine : .format(settings.progressNoteFormat) },
            set: { pane in
                switch pane {
                case .mine:
                    showingMyNotes = true
                case .format(let format):
                    showingMyNotes = false
                    settings.progressNoteFormat = format
                }
            }
        )
    }

    private var generatedNoteView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                // Adapts to the pane's width instead of widening it.
                AdaptiveActionRow {
                    EmptyView()
                } actions: {
                    if noteRunner.isStreaming {
                        Button(role: .destructive) { noteStopping = true; noteRunner.stop() } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    } else if noteRunner.isQueued {
                        // Waiting behind another generation: offer to back out
                        // rather than a Generate button that looks stuck.
                        Button(role: .cancel) { noteStopping = true; noteRunner.stop() } label: {
                            Label("Cancel", systemImage: "xmark")
                        }
                    } else if !summaryText.isEmpty {
                        // With no note yet, the empty-state card below holds the
                        // Generate button (and ⌘G).
                        Button {
                            requestGenerateNote()
                        } label: {
                            Label("Regenerate", systemImage: "sparkles")
                        }
                        .disabled(transcriptText.isEmpty || isEditingNote)
                        .shortcut(AppHotkey.generateNote, help: "Regenerate the note")
                    }
                    if !noteRunner.isStreaming && !noteRunner.isQueued && !isEditingNote {
                        noteLengthMenu
                    }
                    if !summaryText.isEmpty && !noteRunner.isStreaming {
                        if hasPreviousNote && !isEditingNote && !noteRunner.isQueued {
                            Button { restorePreviousNote() } label: {
                                Label("Restore Previous", systemImage: "arrow.uturn.backward")
                            }
                            .help("Swap back to the version you edited before the last regenerate")
                        }
                        if !isEditingNote {
                            Button {
                                noteDraft = summaryText
                                isEditingNote = true
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .disabled(noteRunner.isQueued)
                            .help("Edit this note before it goes in the record")
                        }
                        Button {
                            RichClipboard.write(RichClipboard.payload(markdown: summaryText))
                            noteCopied = true
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                noteCopied = false
                            }
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .help("Copy the note, with its formatting, to paste into your EHR or a document")
                        .popover(isPresented: $noteCopied, arrowEdge: .bottom) {
                            Label("Copied", systemImage: "checkmark.circle.fill")
                                .font(Theme.Typography.control)
                                .foregroundStyle(Theme.text.color)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        }
                        ExportButton(help: "Save this note as a PDF, Word or Markdown file") { exportNote(as: $0) }
                    }
                }
                if let status = noteRunner.queuedStatus {
                    Label(status, systemImage: "clock")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                }
            }
            .buttonStyle(.themed)
            .padding(.horizontal, 20)

            if noteIsOutdated {
                OutdatedNoteBanner(canRegenerate: !transcriptText.isEmpty, onRegenerate: generateNote)
            }

            if summaryText.isEmpty && !noteRunner.isStreaming {
                emptyNoteCard
            } else if summaryText.isEmpty {
                noteWorkingRow
            } else if isEditingNote {
                HStack(spacing: 8) {
                    Label("Editing the \(settings.progressNoteFormat.shortName) note. Regenerating asks before replacing your edits.", systemImage: "pencil")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                    Spacer()
                    Button("Cancel") { isEditingNote = false }
                        .buttonStyle(.themed)
                    Button("Save") { saveEditedNote() }
                        .buttonStyle(.themePrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!NoteEditing.canSave(draft: noteDraft, original: summaryText))
                }
                .padding(.horizontal, 20)
                RichNoteEditor(markdown: $noteDraft, fonts: .serif, minHeight: 200, fills: true, label: "Edit note")
                    .padding([.horizontal, .bottom], 20)
            } else {
                if noteRunner.isStreaming {
                    noteWorkingRow
                } else if noteRunner.progress.stats?.possiblyTruncated == true {
                    Text(AIRunStats.truncationNotice)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                        .padding(.horizontal, 20)
                }
                if !noteRunner.isStreaming, let noteCoverage {
                    Text(noteCoverage)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                        .padding(.horizontal, 20)
                }
                ScrollViewReader { proxy in
                    BoundedScroll {
                        MarkdownMessageView(text: summaryText, style: .note, flashedBlock: flashedNoteBlock)
                            .frame(maxWidth: 680, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                    }
                    .task(id: noteFocusToken) { await showNoteSearchFocus(proxy) }
                }
            }
        }
        .sheet(isPresented: $editingInstructions) {
            let format = settings.progressNoteFormat
            NoteInstructionsSheet(
                format: format,
                current: settings.noteInstructions[format.rawValue] ?? Prompts.defaultInstructions(for: format),
                onSave: { text in
                    settings.setNoteInstructions(text, for: format)
                    editingInstructions = false
                },
                onCancel: { editingInstructions = false }
            )
        }
        .alert("Replace your edited note?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) { generateNote() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You edited this \(settings.progressNoteFormat.shortName) note. Regenerating replaces it; your edited version is kept and can be brought back with Restore Previous.")
        }
    }

    /// Length for every format, effort for long sessions, and the per-format
    /// prompt. Changing length or effort takes effect on the next Regenerate.
    private var noteLengthMenu: some View {
        let format = settings.progressNoteFormat
        let customized = settings.noteInstructions[format.rawValue] != nil
        return Menu {
            Picker("Length", selection: $settings.summaryVerbosity) {
                ForEach(SummaryVerbosity.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Picker(AnswerEffort.label, selection: $settings.noteEffort) {
                ForEach(AnswerEffort.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Edit \(format.shortName) Prompt…\(customized ? " (customized)" : "")") {
                editingInstructions = true
            }
        } label: {
            // AdaptiveLabel, not Label: a Menu's label ignores .labelStyle(.iconOnly).
            AdaptiveLabel(
                title: "Length: \(settings.summaryVerbosity.displayName) · \(settings.noteEffort.displayName)",
                systemImage: "text.alignleft"
            )
        }
        .fixedSize()
        .help("How long the note is, and the AI effort for a long session. \(settings.noteEffort.displayName): \(settings.noteEffort.blurb(for: .note)) Regenerate to apply a change.")
    }

    /// Shown while a note is generated: one line and a bar.
    private var noteWorkingRow: some View {
        NoteProgressRow(
            title: NoteProgress.title(for: generatingFormat),
            progress: noteRunner.progress, speed: integrations.modelSpeed, highWater: noteHighWater)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// No note in this format yet: say why, and offer the one action.
    private var emptyNoteCard: some View {
        let format = settings.progressNoteFormat.shortName
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        return VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 22))
                .foregroundStyle(Theme.muted.color)
            Text("No \(format) note yet")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.text.color)
            Text(transcriptText.isEmpty
                 ? "Transcribe the session first, then draft the note from it."
                 : "Draft one from the transcript and your notes. You can edit it before it goes in the record.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.muted.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                requestGenerateNote()
            } label: {
                HStack(spacing: 8) {
                    Label("Generate \(format) note", systemImage: "sparkles")
                    ShortcutHint(AppHotkey.generateNote, onAccent: true)
                }
            }
            .buttonStyle(.themePrimary)
            .disabled(transcriptText.isEmpty || noteRunner.isQueued)
            .shortcut(
                AppHotkey.generateNote,
                help: transcriptText.isEmpty ? "Transcribe the session first" : "Draft a \(format) note from the transcript"
            )
        }
        .padding(28)
        .frame(maxWidth: 520)
        .overlay(shape.strokeBorder(Theme.line.color, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func saveEditedNote() {
        guard let store = appModel.store else { return }
        guard NoteEditing.canSave(draft: noteDraft, original: summaryText) else { return }
        do {
            try store.saveEditedNote(noteDraft, for: patient, session: session, format: settings.progressNoteFormat)
            summaryText = noteDraft
            isEditingNote = false
            onSessionUpdated()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Regenerate asks first when it would replace the user's edits; an
    /// untouched generated note is replaced straight away. (The Store keeps the
    /// edited text as the previous version either way.)
    private func requestGenerateNote() {
        guard let store = appModel.store else { return }
        let state = store.noteEditState(for: patient, session: session, format: settings.progressNoteFormat)
        if state == .unreadable {
            errorMessage = StoreError.noteUnreadable.localizedDescription
        } else if NoteEditing.shouldArchiveBeforeReplacing(state) {
            confirmRegenerate = true
        } else {
            generateNote()
        }
    }

    private func restorePreviousNote() {
        guard let store = appModel.store else { return }
        do {
            if let restored = try store.restorePreviousNote(for: patient, session: session, format: settings.progressNoteFormat) {
                summaryText = restored
                onSessionUpdated()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func savedCoverage(for format: ProgressNoteFormat) -> String? {
        appModel.store?.noteCoverage(for: patient, session: session, format: format)
    }

    private func refreshHasPreviousNote() {
        guard let store = appModel.store else { hasPreviousNote = false; return }
        hasPreviousNote = store.previousNote(for: patient, session: session, format: settings.progressNoteFormat) != nil
    }

    private var sessionChatNotices: [String] {
        var list: [String] = []
        if let sessionChatCoverage { list.append(sessionChatCoverage) }
        if chatRunner.progress.stats?.possiblyTruncated == true && !isChatSending {
            list.append(AIRunStats.truncationNotice)
        }
        return list
    }

    private var chatTab: some View {
        ChatPaneView(
            title: "this session",
            messages: $chatMessages,
            isSending: isChatSending,
            suggestions: appModel.featureRegistry.contains(id: SuggestedQuestionsFeatureModule.id) ? SuggestedQuestions.session : [],
            onSend: sendChat,
            onStop: { chatRunner.stop() },
            queuedStatus: chatRunner.queuedStatus,
            notices: sessionChatNotices,
            onCompact: { compactChat($0) },
            progress: chatRunner.progress,
            effort: $settings.sessionChatEffort,
            isSessionRecording: recorder.isRecording
        )
    }

    /// Puts this session first for a summary, if it needs one (too long to send
    /// whole, or its patient's history is) and has none. The scheduler builds
    /// it when nothing else is using the model (`DigestScheduler`).
    private func ensureDigest() {
        guard transcriptReadError == nil, !transcriptText.isEmpty else { return }
        integrations.digestScheduler.sessionOpened(patient: patient, session: session)
    }

    private func load() {
        guard let store = appModel.store else { return }
        reloadTranscript()
        transcriptDraft = transcriptText
        if transcriptReadError == nil, let restored = UnsavedTranscriptDrafts.take(for: session.id) {
            transcriptDraft = restored
            restoredDraft = true
        }
        editGuard?.attach(
            dirty: { transcriptIsDirty },
            save: { saveTranscriptDraft() },
            discard: { discardTranscriptEdits() }
        )
        summaryText = savedNote(for: settings.progressNoteFormat)
        noteFingerprint = savedFingerprint(for: settings.progressNoteFormat)
        noteCoverage = savedCoverage(for: settings.progressNoteFormat)
        isEditingNote = false
        refreshHasPreviousNote()
        chatMessages = store.loadSessionChat(for: patient, session: session)
        if let commentStore = appModel.commentStore {
            let storedNote = commentStore.note(sessionID: session.id)
            persistedSessionNote = storedNote
            sessionNote = storedNote
            comments = commentStore.comments(sessionID: session.id)
        }
    }

    /// The saved note for `format` (empty if that format has none yet).
    private func savedNote(for format: ProgressNoteFormat) -> String {
        appModel.store?.note(for: patient, session: session, format: format) ?? ""
    }

    /// The fingerprint recorded when `format`'s note was generated, if any.
    private func savedFingerprint(for format: ProgressNoteFormat) -> String? {
        appModel.store?.noteTranscriptFingerprint(for: patient, session: session, format: format)
    }

    /// The displayed note was generated from an earlier version of the saved
    /// transcript. Hidden while a (re)generation is running.
    private var noteIsOutdated: Bool {
        !summaryText.isEmpty && !noteRunner.isStreaming && !noteRunner.isQueued
            && NoteFreshness.isOutdated(recorded: noteFingerprint, transcript: transcriptText)
    }

    private func editComment(_ comment: SessionComment, _ body: String) {
        guard let commentStore = appModel.commentStore,
              CommentsRailView.canSaveEdit(draft: body, original: comment.body) else { return }
        appModel.updateComment(id: comment.id, body: body)
        comments = commentStore.comments(sessionID: session.id)
    }

    private func deleteComment(_ comment: SessionComment) {
        guard let commentStore = appModel.commentStore else { return }
        commentStore.deleteComment(id: comment.id)
        comments = commentStore.comments(sessionID: session.id)
    }

    /// Whether the app-wide recorder is recording *this* session (vs. another
    /// one started from the menu bar).
    private var isRecordingThisSession: Bool {
        recorder.isRecording
            && recorder.active?.patientSlug == patient.slug
            && recorder.active?.sessionFolder == session.folderName
    }

    private func startRecording() async {
        guard appModel.authorizeNewPHI(), let store = appModel.store else { return }
        let micURL = store.micRecordingURL(for: patient, session: session)
        let callURL = store.callRecordingURL(for: patient, session: session)
        // Refused (another recording is in the way) or failed to start: say why.
        errorMessage = await recorder.start(
            micURL: micURL,
            callURL: callURL,
            context: .init(
                sessionID: session.id,
                patientID: patient.id,
                patientName: patient.name,
                patientSlug: patient.slug,
                sessionFolder: session.folderName
            ),
            protector: appModel.currentProtector
        )
    }

    private func stopRecording() async {
        await recorder.stop()
        onSessionUpdated()
    }

    /// Whether this session is being transcribed right now (the state lives in
    /// the app-level coordinator, so it survives leaving and returning).
    private var isTranscribing: Bool {
        transcription.job(for: session.id) != nil
    }

    /// Waiting behind another session's transcription.
    private var isQueued: Bool {
        transcription.isWaiting(session.id)
    }

    private var offersRecord: Bool {
        SessionActionPolicy.offersRecord(
            hasTranscript: !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            hasRecording: hasAnyRecording, isTranscribing: isTranscribing, isQueued: isQueued
        )
    }

    private var offersTranscribe: Bool {
        SessionActionPolicy.offersTranscribe(
            hasRecording: hasAnyRecording, isTranscribing: isTranscribing, isQueued: isQueued
        )
    }

    private var recordBlocker: String? {
        SessionActionPolicy.recordBlocker(
            isTranscribing: isTranscribing, isQueued: isQueued, isStarting: recorder.isStarting
        )
    }

    private var transcribeBlocker: String? {
        SessionActionPolicy.transcribeBlocker(
            isRecordingThisSession: isRecordingThisSession,
            isRecordingElsewhere: recorder.isBusy && !isRecordingThisSession,
            isTranscribing: isTranscribing,
            isQueued: isQueued,
            hasRecording: hasAnyRecording
        )
    }

    /// Picks up how this session's last transcription ended: reloads the text
    /// and raises the inline notice or the error. Runs both when one finishes
    /// while this screen is up and when the screen appears after one finished.
    private func consumeTranscriptionOutcome() {
        guard let outcome = transcription.takeOutcome(for: session.id) else { return }
        switch outcome {
        case .completed:
            noSpeechNotice = nil
            reloadTranscript()
            // Re-transcribing was the user's choice: the new text wins over any
            // unsaved edits to the old one, so a later Save can't put the old
            // text back.
            transcriptDraft = transcriptText
            onSessionUpdated()
        case .blank(let notice):
            // Nothing was transcribed; any existing transcript is untouched.
            noSpeechNotice = notice
            onSessionUpdated()
        case .completedAudioKept(let notice):
            reloadTranscript()
            transcriptDraft = transcriptText
            noSpeechNotice = notice
            onSessionUpdated()
        case .cancelled:
            break
        case .failed(let message):
            errorMessage = message
        }
    }

    /// Reads the saved transcript. A file that exists but can't be read turns
    /// editing off (and blocks Save) rather than being treated as empty, so it is
    /// never overwritten.
    private func reloadTranscript() {
        guard let store = appModel.store else { return }
        do {
            let saved = try store.readTranscript(for: patient, session: session)
            transcriptText = saved ?? ""
            hasTranscript = saved != nil
            transcriptReadError = nil
        } catch {
            transcriptText = ""
            hasTranscript = true
            transcriptReadError = error.localizedDescription
        }
    }

    /// Streams a clinical progress note (in the selected format) into the
    /// summary view as it writes, then persists the finished note under that
    /// format. Reuses the same calm word-by-word reveal as chat, with a working
    /// Stop. The format is captured up front so a picker change mid-stream can't
    /// misfile the result into another format's note.
    private func generateNote() {
        guard let store = appModel.store else { return }
        // One note per session at a time, even across leaving and reopening the session.
        let jobLabel = "progress note \(session.id.uuidString)"
        guard !integrations.inferenceQueue.hasJob(labelled: jobLabel) else {
            if noteStopping {
                // Just stopped: start again once the old job has unwound, with no alert.
                // Only the first waiter goes on; a second click finds the flag already cleared.
                guard noteWaiter == nil else { return }
                noteWaiter = Task { @MainActor in
                    let deadline = Date().addingTimeInterval(10)
                    while integrations.inferenceQueue.hasJob(labelled: jobLabel), !Task.isCancelled, Date() < deadline {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    // A cancelled waiter may already have been replaced; leave the new one alone.
                    if !Task.isCancelled { noteWaiter = nil }
                    guard !Task.isCancelled, noteStopping else { return }
                    noteStopping = false
                    // Still running after the wait: say so, as for any second Generate.
                    if integrations.inferenceQueue.hasJob(labelled: jobLabel) {
                        errorMessage = "A note for this session is already being written."
                    } else {
                        generateNote()
                    }
                }
            } else {
                errorMessage = "A note for this session is already being written."
            }
            return
        }
        noteStopping = false
        let format = settings.progressNoteFormat
        generatingFormat = format
        noteHighWater = ProgressHighWater()
        let verbosity = settings.summaryVerbosity
        let instructions = settings.noteInstructions[format.rawValue]
        // Snapshot the inputs now; the request itself is only made when the
        // queue starts this job (it may be waiting behind a chat answer).
        let service = integrations.makeAssistantService(report: noteRunner.reporter, clientName: patient.name)
        let transcript = transcriptText
        let notes = sessionNote
        let sessionComments = settings.includeCommentsInDrafts ? comments : []
        let patientBackground = settings.includePatientBackground ? patient.aiBackgroundBlock : ""
        let effort = settings.noteEffort
        let riskPhrases = settings.riskPhrases
        let model = service.model
        let produced = CoverageBox()
        noteRunner.start(
            queue: integrations.inferenceQueue,
            kind: .note,
            label: jobLabel,
            readTitle: "Reading the session",
            writeTitle: "Writing the note",
            makeStream: {
                // The job has started: drop the old note so the pane can show
                // progress until the first token.
                if settings.progressNoteFormat == format { summaryText = ""; noteCoverage = nil }
                return LongSessionNote.stream(
                    format: format,
                    transcript: transcript,
                    notes: notes,
                    comments: sessionComments,
                    patientBackground: patientBackground,
                    verbosity: verbosity,
                    instructions: instructions,
                    effort: effort,
                    riskPhrases: riskPhrases,
                    service: service,
                    builder: integrations.digests,
                    sessionID: session.id,
                    loadDigest: { [patient, session] in
                        await Task.detached { store.digest(for: patient, session: session, model: model) }.value
                    },
                    saveDigest: { [patient, session] in try store.saveDigest($0, for: patient, session: session) },
                    sectionCache: .store(store, patient: patient, session: session),
                    live: { started, change in noteRunner.update(started: started, change) },
                    coverage: {
                        produced.text = $0
                        if settings.progressNoteFormat == format { noteCoverage = $0 }
                    }
                )
            },
            onReveal: { text in
                if settings.progressNoteFormat == format { summaryText = text }
            },
            onError: { error in
                if let incident = AIEngineIncident.from(error: error) {
                    engineRetries.set({ generateNote() }, for: .note)
                    engineIncident = incident
                } else {
                    errorMessage = error.localizedDescription
                }
                // The reveal blanked the pane; put back what is actually saved.
                if settings.progressNoteFormat == format {
                    summaryText = savedNote(for: format)
                    noteCoverage = savedCoverage(for: format)
                }
            },
            onFinish: { raw in
                // Save the tidied text, so copy, export and edit see the same
                // paragraphs and labels the pane shows.
                let final = SpeakerCodes.scrub(NoteMarkdown.tidy(raw), clientName: patient.name)
                // Stopped part-way: say the saved note is only what was written so far.
                if noteStopping, !final.isEmpty, !(produced.text ?? "").contains(LongSessionNote.CheckOutcome.stopped.text) {
                    produced.text = [produced.text, LongSessionNote.stoppedEarlyText].compactMap { $0 }.joined(separator: " ")
                    if settings.progressNoteFormat == format { noteCoverage = produced.text }
                }
                guard !final.isEmpty else {
                    // Stopped before the first token, or empty output: the pane
                    // was cleared at start, so put back what is saved.
                    if settings.progressNoteFormat == format {
                        summaryText = savedNote(for: format)
                        noteCoverage = savedCoverage(for: format)
                    }
                    return
                }
                if settings.progressNoteFormat == format { summaryText = final }
                do {
                    try store.saveGeneratedNote(final, for: patient, session: session, format: format, generatedFromTranscript: transcript, coverage: produced.text)
                } catch {
                    errorMessage = error.localizedDescription
                    if settings.progressNoteFormat == format {
                        summaryText = savedNote(for: format)
                        noteCoverage = savedCoverage(for: format)
                    }
                    return
                }
                // Record which transcript this note came from (the snapshot the
                // request used, not whatever the transcript is by now).
                if settings.progressNoteFormat == format {
                    refreshHasPreviousNote()
                    noteFingerprint = NoteFreshness.fingerprint(of: transcript)
                    // The format may have been switched away and back during the run.
                    noteCoverage = savedCoverage(for: format)
                }
                onSessionUpdated()
                Task {
                    await integrations.makeNotifier().post(
                        SessionNotifications.summaryReady(
                            patientName: patient.name, date: session.date,
                            policy: .current(showFullName: settings.notificationsShowPatientNames)
                        )
                    )
                }
            }
        )
    }

    private func sendChat(_ question: String) {
        guard let store = appModel.store else { return }
        // Past ChatMemory's budget, compact first so the answer still has the
        // whole conversation, the earlier part in summary.
        if ChatMemory.needsCompaction(chatMessages) {
            compactChat("") { sendChat(question) }
            return
        }
        let userMessage = ChatMessage(role: .user, text: question)
        chatMessages.append(userMessage)
        isChatSending = true
        let assistantID = UUID()
        // Snapshot the inputs now; the request itself is only made when the
        // queue starts this job (it may be waiting behind the note).
        let service = integrations.makeAssistantService(report: chatRunner.reporter, clientName: patient.name)
        let transcript = transcriptText
        let notes = sessionNote
        let sessionComments = comments
        let patientBackground = settings.includePatientBackground ? patient.aiBackgroundBlock : ""
        let history = chatMessages
        let effort = settings.sessionChatEffort
        let model = service.model
        let patient = patient
        let session = session
        sessionChatCoverage = nil
        chatRunner.start(
            queue: integrations.inferenceQueue,
            kind: .sessionChat,
            label: "session question",
            readTitle: "Reading the session",
            writeTitle: "Writing the answer",
            makeStream: {
                LongSessionChat.stream(
                    transcript: transcript,
                    notes: notes,
                    comments: sessionComments,
                    patientBackground: patientBackground,
                    history: history,
                    question: question,
                    effort: effort,
                    sessionID: session.id,
                    sessionDate: session.date,
                    folderName: session.folderName,
                    service: service,
                    builder: integrations.digests,
                    loadDigest: {
                        await Task.detached { store.digest(for: patient, session: session, model: model) }.value
                    },
                    saveDigest: { try store.saveDigest($0, for: patient, session: session) },
                    sectionCache: .store(store, patient: patient, session: session),
                    live: { started, change in chatRunner.update(started: started, change) },
                    coverage: { sessionChatCoverage = $0 }
                )
            },
            onReveal: { text in chatMessages.upsert(id: assistantID, role: .assistant, text: text) },
            onError: { error in
                isChatSending = false
                if let incident = AIEngineIncident.from(error: error) {
                    // The question stays in the conversation (nothing is lost if the
                    // alert is cancelled); a retry takes the unanswered turn out
                    // first so the question is asked once.
                    engineRetries.set({
                        chatMessages.removeTurn(startingAt: userMessage.id)
                        sendChat(question)
                    }, for: .chat)
                    engineIncident = incident
                } else {
                    errorMessage = error.localizedDescription
                }
            },
            onFinish: { _ in
                isChatSending = false
                appModel.attemptSave("chat") { try store.saveSessionChat(chatMessages, for: patient, session: session) }
            },
            // Cancelled while waiting: the question never ran, so take it back
            // out of the conversation rather than leave it unanswered.
            onCancelledWhileQueued: {
                chatMessages.removeAll { $0.id == userMessage.id }
                isChatSending = false
            }
        )
    }
}

extension SessionDetailView {
    /// Replaces the conversation so far with the model's summary of it
    /// (`/compact`, the Compact button, or a send past the budget), then runs
    /// `next`. A stopped or failed summary is discarded: a partial one would
    /// stand in for messages it doesn't cover.
    fileprivate func compactChat(_ focus: String, then next: (() -> Void)? = nil) {
        guard let store = appModel.store, !chatMessages.isEmpty else { return }
        isChatSending = true
        let summaryID = UUID()
        let service = integrations.makeAssistantService(report: chatRunner.reporter, clientName: patient.name)
        let history = chatMessages
        chatRunner.start(
            queue: integrations.inferenceQueue,
            kind: .sessionChat,
            label: "conversation summary",
            readTitle: "Reading the conversation",
            writeTitle: "Summarizing the conversation",
            makeStream: { service.streamCompaction(history: history, focus: focus) },
            onReveal: { text in chatMessages.upsert(id: summaryID, role: .summary, text: text) },
            onError: { error in
                isChatSending = false
                chatMessages.removeAll { $0.id == summaryID }
                errorMessage = error.localizedDescription
            },
            onFinish: { text in
                isChatSending = false
                guard !chatRunner.wasStopped, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    chatMessages.removeAll { $0.id == summaryID }
                    return
                }
                appModel.attemptSave("chat") { try store.saveSessionChat(chatMessages, for: patient, session: session) }
                next?()
            },
            onCancelledWhileQueued: { isChatSending = false }
        )
    }
}

/// Carries the composer card's measured height up to the overlay that places it.
private struct ComposerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 230
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The card the inline comment composer shows under a transcript passage: the
/// line's time stamp, the quoted passage, a multi-line editor (focused on open)
/// and Cancel / Save. Return adds a new line; Command-Return saves; Esc cancels.
private struct InlineCommentComposerCard: View {
    let timeLabel: String?
    let quote: String
    @Binding var text: String
    var onCancel: () -> Void
    var onSave: () -> Void

    @State private var focused = false

    private var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let timeLabel { Chip(timeLabel) }
                Text("Comment on selected text")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
            }
            Text("“\(TranscriptTimeline.spokenText(quote))”")
                .font(.system(size: 13).italic())
                .foregroundStyle(Theme.muted.color)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            editor
            Text("Comments are included when the progress note is drafted.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .center, spacing: 12) {
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    ShortcutHint(AppHotkey.saveComment)
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.themed)
                        .keyboardShortcut(.cancelAction)
                    Button("Save comment", action: onSave)
                        .buttonStyle(.themePrimary)
                        .disabled(!canSave)
                        .shortcut(AppHotkey.saveComment, help: "Save this comment")
                }
                .fixedSize()
            }
        }
        .padding(14)
        .background(Theme.window.color, in: shape)
        .overlay(shape.strokeBorder(Theme.accent.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Comment on selected text")
        .onExitCommand(perform: onCancel)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var editor: some View {
        ThemeTextArea(
            text: $text,
            placeholder: "Add a comment…",
            height: .flexible(min: 84),
            accessibilityLabel: "Comment",
            isFocused: $focused
        )
        .frame(height: 84)
    }
}

/// Holds what a long-session note says it was written from, between the run's
/// first report and the save, whatever the picker shows meanwhile.
private final class CoverageBox {
    var text: String?
}
