import SwiftUI
import UniformTypeIdentifiers
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
        LiveTimeline { now in
            VStack(alignment: .leading, spacing: 6) {
                AIStatusLineView(text: NoteProgress.statusLine(title: title, progress, now: now))
                ThemeProgressBar(value: highWater.clamp(NoteProgress.fraction(progress, now: now, speed: speed)))
                    .frame(maxWidth: 240)
            }
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

    /// The transcript as saved on disk, the therapist's notes and the margin
    /// comments: what notes and answers are written from.
    @StateObject private var material = SessionInputs()
    @StateObject private var note = SessionNoteModel()
    @StateObject private var chat = SessionChatModel()
    /// The transcript as saved on disk. Generated notes, chat and staleness all
    /// key off this, never off the draft.
    private var transcriptText: String {
        get { material.transcriptText }
        nonmutating set { material.transcriptText = newValue }
    }
    private var sessionNote: String {
        get { material.myNotes }
        nonmutating set { material.myNotes = newValue }
    }
    /// Every comment on the session: the transcript's, and those on each
    /// format's note.
    private var allComments: [SessionComment] {
        get { material.comments }
        nonmutating set { material.comments = newValue }
    }
    /// The comments on the transcript.
    private var comments: [SessionComment] { allComments.filter { $0.format == nil } }
    /// The comments on the note shown for the chosen format.
    private var noteComments: [SessionComment] {
        allComments.filter { $0.format == settings.progressNoteFormat }
    }
    private var summaryText: String {
        get { note.summaryText }
        nonmutating set { note.summaryText = newValue }
    }
    private var noteCoverage: String? { note.noteCoverage }
    private var isEditingNote: Bool {
        get { note.isEditingNote }
        nonmutating set { note.isEditingNote = newValue }
    }
    private var hasPreviousNote: Bool { note.hasPreviousNote }
    private var noteRunner: ChatStreamRunner { note.runner }
    private var chatRunner: ChatStreamRunner { chat.runner }
    private var isChatSending: Bool { chat.isSending }
    private var chatMessages: [ChatMessage] {
        get { chat.messages }
        nonmutating set { chat.messages = newValue }
    }
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
    @State private var editingInstructions = false
    /// The note text as last read from / written to the store. `load()` assigns
    /// `sessionNote` programmatically, which fires `onChange`; comparing against
    /// this keeps that echo (and any no-op change) from being saved back.
    @State private var persistedSessionNote: String = ""
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
    @State private var noteSelection = ""
    @State private var noteSelectionRange: NSRange?
    @State private var showNoteComposer = false
    @State private var notePendingQuote = ""
    @State private var notePendingQuoteStart: Int?
    @State private var noteComposerAnchor: CGRect?
    @State private var noteComposerHeight: CGFloat = 230
    @State private var noteInlineCommentBody = ""
    @State private var focusedNoteCommentID: String?
    /// Bumped on every note focus request (a comment, or a search match), so
    /// the note scrolls to and flashes it each time.
    @State private var noteFocusToken = 0
    /// Bumped for comment focus only, so a collapsed note comments pane opens
    /// for a comment but not for a search match.
    @State private var noteCommentRevealToken = 0
    /// Which side of the note / comments split the reader folded away.
    @State private var noteSplitCollapsed: TranscriptSplit.Side?
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
    /// The search match to scroll to and flash in the drafted note. Shown on
    /// the next `noteFocusToken`, like a focused note comment.
    @State private var noteSearchFocus: SearchMatchFocus?
    /// Set when the last transcription came back blank and the recording was
    /// kept (see `AudioRetentionPolicy.decision`); shown inline, not as an alert.
    @State private var noSpeechNotice: String?
    @State private var errorMessage: String?
    /// How the last export ended, shown until dismissed.
    @State private var exportResult: SaveOutcome?
    /// Set when note generation or a chat answer failed because the local AI
    /// engine is down; `engineRetries` re-runs whatever failed after the fix.
    @State private var engineIncident: AIEngineIncident?
    @State private var engineRetries = PendingRetries<EngineRetryKind, () -> Void>()
    @State private var confirmationMessage: String?
    @State private var showScheduleSheet = false
    @State private var showRecordingConsent = false
    /// What the consent sheet is in front of: recording, importing a file, or a change.
    @State private var consentPurpose: ConsentSheetPurpose = .record
    /// The session's consent line, and whether Change… is offered.
    @State private var consentLine = ""
    @State private var canChangeConsent = false
    @State private var showAudioImporter = false
    @State private var isImportingAudio = false
    @State private var pendingExport: ExportConfirmation?
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
                TranscriptionProgressView(job: job) {
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
        .onChange(of: selectedTab) { refreshConsent() }
        .selectablePatientText()
        .onAppear {
            appModel.access.viewedSession(session.id)
            if initialShowingMyNotes {
                showingMyNotes = true
            } else if let initialNoteFormat {
                showingMyNotes = false
                settings.progressNoteFormat = initialNoteFormat
            }
            selectedTab = initialTab

            load()

            if let initialFocusedCommentID {
                if initialTab == .notes {
                    focusNoteComment(initialFocusedCommentID)
                } else {
                    focusComment(initialFocusedCommentID)
                }
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
            note.cancelWaiter()
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
            note.showSaved(for: newFormat)
            // Note comments belong to one format.
            reloadNoteComments()
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
        .alert("Not signed yet", isPresented: Binding(get: { note.reviewBlock != nil }, set: { if !$0 { note.reviewBlock = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(note.reviewBlock ?? "")
        }
        .confirmationDialog(NoteLifecycle.signTitle, isPresented: $note.confirmingSign, titleVisibility: .visible) {
            Button("Sign note") { note.sign() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(NoteLifecycle.signMessage)
        }
        .confirmationDialog(NoteLifecycle.reopenTitle, isPresented: $note.confirmingReopen, titleVisibility: .visible) {
            Button("Reopen as draft") { note.reopen() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(NoteLifecycle.reopenMessage)
        }
        .alert("Done", isPresented: Binding(get: { confirmationMessage != nil }, set: { if !$0 { confirmationMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(confirmationMessage ?? "")
        }
        .dismissOnLock { showScheduleSheet = false; editingInstructions = false; pendingExport = nil; showRecordingConsent = false; showAudioImporter = false }
        .sheet(isPresented: $showScheduleSheet) { scheduleSheet }
        .sheet(isPresented: $showRecordingConsent) {
            RecordingConsentSheet(
                purpose: consentPurpose,
                policy: appModel.consentPolicy(for: patient),
                onCancel: { showRecordingConsent = false },
                onConfirm: { capture in
                    showRecordingConsent = false
                    do {
                        try appModel.recordConsent(capture, patient: patient, session: session)
                    } catch {
                        errorMessage = error.localizedDescription
                        refreshConsent()
                        return
                    }
                    refreshConsent()
                    switch consentPurpose {
                    case .record: Task { await startRecording() }
                    case .importAudio: pickAudioFile()
                    case .change: break
                    }
                }
            )
        }
        .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result, !urls.isEmpty { importAudio(from: urls) }
        }
        .exportConfirmation($pendingExport, settings: settings)
        .exportResultAlert($exportResult)
    }

    /// Title and consent line on one row when they fit; in a narrow column the
    /// consent line goes under the title, wrapping if it must.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                headerTitle
                Spacer(minLength: 0)
                consentStatus(alignment: .trailing).fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                headerTitle
                consentStatus(alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(minHeight: 52)
        .background(Theme.window.color)
    }

    private var headerTitle: some View {
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
        }
    }

    /// "Consent: verbal, from the patient · …", with Change… until a note is signed.
    private func consentStatus(alignment: TextAlignment) -> some View {
        HStack(spacing: 6) {
            // Wraps rather than cutting off when the header is narrow.
            Text(consentLine)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)
            if canChangeConsent {
                Button(RecordingConsent.changeTitle) {
                    // A note may have been signed since the line was drawn.
                    refreshConsent()
                    guard canChangeConsent else { return }
                    consentPurpose = .change
                    showRecordingConsent = true
                }
                .buttonStyle(.themed)
                .controlSize(.small)
                .help("Record this session's consent again")
            }
        }
    }

    private func refreshConsent() {
        do {
            consentLine = RecordingConsent.sessionLine(try appModel.consentStatus(patient: patient, session: session))
            canChangeConsent = appModel.canChangeConsent(patient: patient, session: session)
        } catch {
            consentLine = error.localizedDescription
            canChangeConsent = false
        }
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
                    .disabled(recordBlocker != nil || isImportingAudio)
                    if appModel.importsAudio() {
                        Button {
                            requestAudioImport()
                        } label: {
                            Label("Import Audio…", systemImage: "square.and.arrow.down")
                        }
                        .help(recordBlocker ?? "Use an audio file you already have as this session's recording")
                        .disabled(recordBlocker != nil || isImportingAudio)
                    }
                    if isImportingAudio {
                        ProgressView().controlSize(.small)
                    }
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
        LiveTimeline { now in
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.recording.color)
                    .frame(width: 8, height: 8)
                    .opacity(recorder.isPaused ? 0.5 : 1)
                Text(recordingElapsed(at: now))
                    .font(Theme.Typography.control.monospacedDigit())
                    .foregroundStyle(Theme.recording.color)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(recorder.isPaused ? "Paused" : "Recording, \(recordingElapsed(at: now))")
        }
        .padding(.leading, 4)
    }

    /// This session is recording and has no transcript yet: the pane is the
    /// clock, large enough to read from across the room.
    private var recordingPanel: some View {
        VStack(spacing: 14) {
            Chip(recorder.isPaused ? "Paused" : "Recording", tone: .recording, showsDot: true)
            LiveTimeline { now in
                Text(recordingElapsed(at: now))
                    .font(Theme.Typography.timer)
                    .foregroundStyle(recorder.isPaused ? Theme.muted.color : Theme.text.color)
                    .accessibilityLabel("Elapsed \(recordingElapsed(at: now))")
            }
            InputLevelMeters(levels: recorder.levels, isPaused: recorder.isPaused)
            if let problem = recorder.callAudioProblem {
                callAudioNotice("Only your microphone is being recorded. \(problem)")
            } else if recorder.callAudioSilent, !recorder.isPaused {
                callAudioNotice("No call audio detected. Only your microphone is being recorded. If the other person is speaking, make sure the call plays through this Mac, and that Aletheia is allowed under Screen & System Audio Recording.")
            }
            CallAudioDebugView(enabled: settings.debugDiagnosticsEnabled, recorder: recorder)
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
            let suggestedName = FileSaver.exportFileName(forPatientNamed: patient.name, "Session", dateStr) + ".ics"
            icsSaved = FileSaver.saveICS(icsText, suggestedName: suggestedName)
        }
        var calendarFailure: String?
        do {
            try await integrations.makeCalendarScheduler().schedule(draft)
        } catch {
            calendarFailure = error.localizedDescription
        }
        showScheduleSheet = false
        switch ScheduleNextSession.outcome(eventTitle: draft.title, calendarFailure: calendarFailure, icsSaved: icsSaved) {
        case let .confirmation(message): confirmationMessage = message
        case let .error(message): errorMessage = message
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
        guard appModel.store != nil else { return }
        ExportConfirmation(
            patientName: patient.name, noun: "session (note and transcript)", count: 1, fileType: format.title,
            scope: .session
        ) { saveSession(as: format) }
        .begin(skipSingleNote: settings.skipSingleNoteExportConfirmation) { pendingExport = $0 }
    }

    private func saveSession(as format: ExportFormat) {
        guard let store = appModel.store else { return }
        let document = ExportDocument(markdown: store.exportSessionMarkdown(patient: patient, session: session))
        let base = FileSaver.exportFileName(forPatientNamed: patient.name, String(session.folderName.prefix(10)))
        let outcome = ExportRenderer.save(document, as: format, baseName: base)
        if case .saved = outcome {
            appModel.recordAudit(.recordExported, subjectID: session.id.uuidString, detail: .exportedSession(format))
        } else if case .failed = outcome {
            appModel.recordAudit(.exportFailed, subjectID: session.id.uuidString, detail: .exportedSession(format))
        }
        exportResult = outcome.shown
    }

    /// Saves the note on screen in `format`, after the usual save panel.
    private func exportNote(as format: ExportFormat) {
        guard note.mayLeave(message: NoteLifecycle.reviewToExport) else { return }
        ExportConfirmation(
            patientName: patient.name, noun: "note", count: 1, fileType: format.title, scope: .singleNote
        ) { saveNote(as: format) }
        .begin(skipSingleNote: settings.skipSingleNoteExportConfirmation) { pendingExport = $0 }
    }

    private func saveNote(as format: ExportFormat) {
        let noteFormat = settings.progressNoteFormat.shortName
        let dateStr = String(session.folderName.prefix(10))
        let document = ExportDocument(
            title: patient.name,
            subtitle: "\(noteFormat) · \(Self.dateFormatter.string(from: session.date))",
            markdown: summaryText
        )
        let base = FileSaver.exportFileName(forPatientNamed: patient.name, dateStr, noteFormat)
        let outcome = ExportRenderer.save(document, as: format, baseName: base)
        if case .saved = outcome {
            appModel.recordAudit(.recordExported, subjectID: session.id.uuidString, detail: .exportedNote(settings.progressNoteFormat, format))
        } else if case .failed = outcome {
            appModel.recordAudit(.exportFailed, subjectID: session.id.uuidString, detail: .exportedNote(settings.progressNoteFormat, format))
        }
        exportResult = outcome.shown
    }

    /// Saves the psychotherapy note on its own, after the authorization
    /// confirmation. Never part of a progress-note export.
    private func exportPsychotherapyNote(as format: ExportFormat) {
        ExportConfirmation(
            patientName: patient.name, noun: "session", count: 1, fileType: format.title,
            scope: .psychotherapy
        ) { savePsychotherapyNote(as: format) }
        .begin(skipSingleNote: false) { pendingExport = $0 }
    }

    private func savePsychotherapyNote(as format: ExportFormat) {
        let detail = AuditDetail.exportedPsychotherapyNote(format)
        guard let document = try? PsychotherapyExport.sessionDocument(
            patientName: patient.name, date: session.date, note: sessionNote, authorized: true) else { return }
        let outcome = ExportRenderer.save(
            document, as: format,
            baseName: PsychotherapyExport.sessionFileBase(patientName: patient.name, date: session.date))
        if case .saved = outcome {
            appModel.recordAudit(.recordExported, subjectID: session.id.uuidString, detail: detail)
        } else if case .failed = outcome {
            appModel.recordAudit(.exportFailed, subjectID: session.id.uuidString, detail: detail)
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
                if note.sessionHasSigned {
                    Label("A note for this session is signed, so the transcript is read-only. Reopen the note as a draft to change it.", systemImage: "lock")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
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
                        isEditable: transcriptReadError == nil && !note.sessionHasSigned,
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
        allComments = commentStore.comments(sessionID: session.id)
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
            focusedNoteCommentID = nil
            noteSearchFocus = initialSearchFocus
            noteFocusToken += 1
        case .ask:
            break
        }
    }

    /// What the note scrolls to and flashes on the next `noteFocusToken`: the
    /// focused comment, or else the search match it was opened at (in the
    /// rendered note, where the reader's offsets are).
    private var noteFocus: TranscriptFocus? {
        if let focusedNoteCommentID { return .comment(focusedNoteCommentID) }
        return noteSearchFocus?.noteRange(in: renderedNote, note: summaryText).map { .range($0) }
    }

    /// The note's text as the reader shows it (see `NoteReaderView.rendered`).
    private var renderedNote: String { NoteReaderView.rendered(summaryText).string }

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
            note.showSaved(for: initialNoteFormat)
            reloadNoteComments()
        }
        selectedTab = initialTab
        if let initialFocusedCommentID {
            if initialTab == .notes {
                focusNoteComment(initialFocusedCommentID)
            } else {
                focusComment(initialFocusedCommentID)
            }
        }
        applySearchFocus()
    }

    private func resolveComment(_ comment: SessionComment, _ resolved: Bool) {
        guard let commentStore = appModel.commentStore else { return }
        appModel.setCommentResolved(id: comment.id, resolved: resolved)
        allComments = commentStore.comments(sessionID: session.id)
        // A resolved comment loses its highlight; don't keep focusing it.
        if resolved, focusedCommentID == comment.id { focusedCommentID = nil }
    }

    /// True when the draft differs from the saved transcript.
    private var transcriptIsDirty: Bool { transcriptDraft != transcriptText }

    /// Writes the draft as the transcript. On failure the draft is kept as it is
    /// and the error is shown; nothing is lost. Returns whether it was saved.
    @discardableResult
    private func saveTranscriptDraft() -> Bool {
        guard transcriptReadError == nil, !note.sessionHasSigned else { return false }
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
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                PsychotherapyNoteBanner()
                Spacer(minLength: 8)
                ExportButton(
                    title: "Export psychotherapy note…",
                    help: "Save this note on its own, apart from the clinical record. You'll confirm you have authorization first."
                ) { exportPsychotherapyNote(as: $0) }
                    .buttonStyle(.themed)
                    .disabled(sessionNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            RichNoteEditor(
                markdown: $material.myNotes,
                placeholder: "Your private process notes for this session…",
                fonts: .sans,
                minHeight: 160,
                fills: true,
                label: NoteKind.psychotherapy.title
            )
            .padding([.horizontal, .bottom], 20)
            .onChange(of: sessionNote) { _, newValue in
                guard newValue != persistedSessionNote else { return }
                persistedSessionNote = newValue
                appModel.saveNote(sessionID: session.id, text: newValue)
            }
        }
    }

    private func notesPanePicker(locked: Bool) -> some View {
        ThemeSegmentedControl(
            options: NotesPane.all.map { ThemeTab(value: $0, title: $0.label) },
            selection: notesPaneBinding,
            sizing: .fitted
        )
        .disabled(locked)
        .opacity(locked ? 0.55 : 1)
        .accessibilityLabel("Note")
        .hoverTip(showingMyNotes ? HelpTips.myNotes : nil)
    }

    /// The Notes tab: one picker across the drafted formats and the therapist's
    /// own notes. Switching is locked while a note is generating or being edited.
    private var notesTab: some View {
        let locked = noteRunner.isStreaming || noteRunner.isQueued || isEditingNote
        return VStack(alignment: .leading, spacing: 14) {
            // Scrolls sideways when the column is too narrow for every format,
            // rather than widening the column past the window.
            ViewThatFits(in: .horizontal) {
                notesPanePicker(locked: locked)
                ScrollView(.horizontal, showsIndicators: false) {
                    notesPanePicker(locked: locked)
                }
            }
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
                    reloadNoteComments()
                }
            }
        )
    }

    private var generatedNoteView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                // Adapts to the pane's width instead of widening it.
                AdaptiveActionRow {
                    Text(NoteKind.progress.title).eyebrowStyle()
                } actions: {
                    if noteRunner.isStreaming {
                        Button(role: .destructive) { note.stop() } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    } else if noteRunner.isQueued {
                        // Waiting behind another generation: offer to back out
                        // rather than a Generate button that looks stuck.
                        Button(role: .cancel) { note.stop() } label: {
                            Label("Cancel", systemImage: "xmark")
                        }
                    } else if !summaryText.isEmpty && !note.noteLocked {
                        // With no note yet, the empty-state card below holds the
                        // Generate button (and ⌘G).
                        Button {
                            note.requestGenerate()
                        } label: {
                            Label("Regenerate", systemImage: "sparkles")
                        }
                        .disabled(transcriptText.isEmpty || isEditingNote)
                        .shortcut(AppHotkey.generateNote, help: "Regenerate the note")
                    }
                    if !noteRunner.isStreaming && !noteRunner.isQueued && !isEditingNote && !note.noteLocked {
                        noteLengthMenu
                    }
                    if !summaryText.isEmpty && !noteRunner.isStreaming {
                        if hasPreviousNote && !isEditingNote && !noteRunner.isQueued && !note.noteLocked {
                            Button { note.restorePrevious() } label: {
                                Label("Restore Previous", systemImage: "arrow.uturn.backward")
                            }
                            .help("Swap back to the version you edited before the last regenerate")
                        }
                        if note.noteLocked {
                            Button { note.confirmingReopen = true } label: {
                                Label("Reopen as draft…", systemImage: "lock.open")
                            }
                            .help("Make this signed note editable again. This is recorded in the activity log.")
                        } else if !isEditingNote {
                            Button {
                                beginNoteInlineComment()
                            } label: {
                                Label("Comment", systemImage: "text.bubble")
                            }
                            .disabled(noteSelection.isEmpty || noteRunner.isQueued)
                            .help(noteSelection.isEmpty
                                  ? "Select a passage in the note to comment on it"
                                  : "Add a comment on the selected passage in this note")
                            Button {
                                note.beginEditing()
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .disabled(noteRunner.isQueued)
                            .help("Edit this note before it goes in the record")
                            Button { note.confirmingSign = true } label: {
                                Label(NoteLifecycle.signButton, systemImage: "signature")
                            }
                            .disabled(noteRunner.isQueued)
                            .help("Confirm you have reviewed this note. A signed note is read-only.")
                        }
                        Button {
                            note.copyNote()
                        } label: {
                            Label(note.copyFeedback.title, systemImage: note.copyFeedback.justCopied ? "checkmark.circle.fill" : "doc.on.doc")
                        }
                        .help("Copy the note, with its formatting, to paste into your EHR or a document")
                        ExportButton(title: "Export progress note…", help: "Save this progress note as a PDF, Word or Markdown file. Your psychotherapy note is never included.") { exportNote(as: $0) }
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

            if !summaryText.isEmpty && !noteRunner.isStreaming && !isEditingNote {
                noteStatusRow
            }

            if note.noteIsOutdated {
                OutdatedNoteBanner(canRegenerate: !transcriptText.isEmpty, onRegenerate: { note.generate() })
            }

            if summaryText.isEmpty && !noteRunner.isStreaming && !noteRunner.isQueued {
                // Scrolls in a short window so the tab never outgrows it.
                ScrollView { emptyNoteCard }
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
                    Button("Save") { note.saveEdited() }
                        .buttonStyle(.themePrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!note.canSaveEdit)
                }
                .padding(.horizontal, 20)
                RichNoteEditor(markdown: $note.noteDraft, fonts: .serif, minHeight: 200, fills: true, label: "Edit note")
                    .padding([.horizontal, .bottom], 20)
            } else {
                if noteRunner.isStreaming || noteRunner.isQueued {
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
                        .accessibilityIdentifier("notes.coverage")
                }
                TranscriptSplitView(
                    hasComments: !noteComments.isEmpty,
                    commentCount: noteComments.filter { !$0.resolved }.count,
                    ratio: $settings.transcriptSplitRatio,
                    collapsed: $noteSplitCollapsed,
                    revealToken: noteCommentRevealToken
                ) {
                    NoteReaderView(
                        text: summaryText,
                        comments: activeNoteAnchors,
                        selection: $noteSelection,
                        selectionRange: $noteSelectionRange,
                        onOpenComment: focusNoteComment,
                        focus: noteFocus,
                        focusToken: noteFocusToken,
                        composingRange: noteComposingRange,
                        onComposingRectChange: { noteComposerAnchor = $0 }
                    )
                    .overlay { noteComposerOverlay }
                } comments: {
                    CommentsRailView(
                        comments: noteComments,
                        focusedCommentID: $focusedNoteCommentID,
                        unplacedIDs: TranscriptHighlighter.unplacedIDs(in: renderedNote, comments: activeNoteAnchors),
                        focusToken: noteFocusToken,
                        onFocus: focusNoteComment,
                        onResolve: resolveNoteComment,
                        onDelete: deleteNoteComment,
                        onEdit: editNoteComment
                    )
                    .textSelection(.disabled)
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
        .alert(NoteWords.replaceEditedTitle, isPresented: $note.confirmRegenerate) {
            Button("Regenerate", role: .destructive) { note.generate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You edited this \(settings.progressNoteFormat.shortName) note. Regenerating replaces it; your edited version is kept and can be brought back with Restore Previous.")
        }
        .onChange(of: summaryText) { _, _ in showNoteComposer = false }
        .onChange(of: isEditingNote) { _, editing in if editing { showNoteComposer = false } }
    }

    private var activeNoteAnchors: [TranscriptHighlighter.Anchor] {
        noteComments.filter { !$0.resolved }.map { (id: $0.id, quote: $0.quotedText, start: $0.quoteStart) }
    }

    private var noteComposingRange: NSRange? {
        guard showNoteComposer, let start = notePendingQuoteStart else { return nil }
        let length = (notePendingQuote as NSString).length
        return length > 0 ? NSRange(location: start, length: length) : nil
    }

    private func beginNoteInlineComment() {
        // The selection is a range in the rendered note, not in the Markdown.
        let rendered = renderedNote
        if let range = noteSelectionRange,
           let trimmed = TranscriptHighlighter.trimmed(range, in: rendered) {
            notePendingQuote = (rendered as NSString).substring(with: trimmed)
            notePendingQuoteStart = trimmed.location
        } else {
            notePendingQuote = noteSelection.trimmingCharacters(in: .whitespacesAndNewlines)
            notePendingQuoteStart = nil
        }
        noteInlineCommentBody = ""
        noteComposerAnchor = nil
        showNoteComposer = true
    }

    private func saveNoteInlineComment() {
        let quote = notePendingQuote
        let body = noteInlineCommentBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty, !body.isEmpty else { return }
        let format = settings.progressNoteFormat
        let created = appModel.addComment(
            sessionID: session.id,
            quotedText: quote,
            body: body,
            anchorSeconds: nil,
            quoteStart: notePendingQuoteStart,
            format: format
        )
        // Keep the composer (and the typed comment) open when the save failed.
        guard let created else { return }
        reloadNoteComments()
        showNoteComposer = false
        focusNoteComment(created.id)
    }

    private func focusNoteComment(_ id: String) {
        focusedNoteCommentID = id
        noteSearchFocus = nil
        noteFocusToken &+= 1
        noteCommentRevealToken &+= 1
    }

    private func reloadNoteComments() {
        if let commentStore = appModel.commentStore {
            allComments = commentStore.comments(sessionID: session.id)
        }
        showNoteComposer = false
        noteSelection = ""
        noteSelectionRange = nil
    }

    private func resolveNoteComment(_ comment: SessionComment, _ resolved: Bool) {
        appModel.setCommentResolved(id: comment.id, resolved: resolved)
        reloadNoteComments()
        if resolved, focusedNoteCommentID == comment.id { focusedNoteCommentID = nil }
    }

    private func editNoteComment(_ comment: SessionComment, _ body: String) {
        guard CommentsRailView.canSaveEdit(draft: body, original: comment.body) else { return }
        appModel.updateComment(id: comment.id, body: body)
        reloadNoteComments()
    }

    private func deleteNoteComment(_ comment: SessionComment) {
        guard let commentStore = appModel.commentStore else { return }
        commentStore.deleteComment(id: comment.id)
        reloadNoteComments()
    }

    @ViewBuilder
    private var noteComposerOverlay: some View {
        if showNoteComposer {
            GeometryReader { proxy in
                InlineCommentComposerCard(
                    timeLabel: nil,
                    quote: notePendingQuote,
                    text: $noteInlineCommentBody,
                    onCancel: { showNoteComposer = false },
                    onSave: saveNoteInlineComment
                )
                .frame(width: max(300, proxy.size.width - Self.composerLeading - Self.composerTrailing))
                .background(
                    GeometryReader { card in
                        Color.clear.preference(key: ComposerHeightKey.self, value: card.size.height)
                    }
                )
                .opacity(noteComposerAnchor == nil && noteComposingRange != nil ? 0 : 1)
                .offset(x: Self.composerLeading, y: noteComposerY(in: proxy.size.height))
            }
            .onPreferenceChange(ComposerHeightKey.self) { noteComposerHeight = $0 }
        }
    }

    private func noteComposerY(in paneHeight: CGFloat) -> CGFloat {
        let margin = Self.composerMargin
        let gap = Self.composerGap
        guard let anchor = noteComposerAnchor else { return margin }
        let below = anchor.maxY + gap
        if below + noteComposerHeight <= paneHeight - margin { return max(margin, below) }
        let above = anchor.minY - gap - noteComposerHeight
        if above >= margin { return above }
        return max(margin, paneHeight - noteComposerHeight - margin)
    }

    /// Length for every format, effort for long sessions, and the per-format
    /// prompt. Changing length or effort takes effect on the next Regenerate.
    private var noteLengthMenu: some View {
        let format = settings.progressNoteFormat
        let customized = settings.noteInstructions[format.rawValue] != nil
        return Menu {
            Picker(NoteWords.lengthTitle, selection: $settings.summaryVerbosity) {
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
            Button(NoteWords.editPromptItem(format: format, customized: customized)) {
                editingInstructions = true
            }
        } label: {
            // AdaptiveLabel, not Label: a Menu's label ignores .labelStyle(.iconOnly).
            AdaptiveLabel(
                title: NoteWords.lengthLabel(length: settings.summaryVerbosity, effort: settings.noteEffort),
                systemImage: "text.alignleft"
            )
        }
        // One native pull-down control, so a click anywhere on it opens the
        // menu; the default style only answered clicks on the icon.
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("notes.length")
        .help("How long the note is, and the AI effort for a long session. \(settings.noteEffort.displayName): \(settings.noteEffort.blurb(for: .note)) Regenerate to apply a change.")
    }

    /// Shown while a note is generated: one line and a bar.
    private var noteWorkingRow: some View {
        NoteProgressRow(
            title: NoteProgress.title(for: note.generatingFormat),
            progress: noteRunner.progress, speed: integrations.modelSpeed, highWater: note.noteHighWater)
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
            Text(NoteWords.emptyTitle(format: settings.progressNoteFormat))
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
                note.requestGenerate()
            } label: {
                HStack(spacing: 8) {
                    Label(NoteWords.generateButton(format: settings.progressNoteFormat), systemImage: "sparkles")
                    ShortcutHint(AppHotkey.generateNote, onAccent: true)
                }
            }
            .buttonStyle(.themePrimary)
            .disabled(transcriptText.isEmpty || noteRunner.isQueued)
            .accessibilityIdentifier("notes.generate")
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

    /// The draft badge, or who signed the note and when.
    private var noteStatusRow: some View {
        HStack(spacing: 8) {
            switch note.noteStatus {
            case .draft:
                if note.noteIsAI { Chip(NoteLifecycle.draftBadge, tone: .warn) }
            case .signed(let record):
                Chip("Signed", tone: .ok)
                Text(NoteLifecycle.signedLine(record))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
            case .altered:
                Chip("Altered after signing", tone: .warn)
                Text(NoteLifecycle.alteredNotice)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
    }

    private var chatTab: some View {
        ChatPaneView(
            title: ChatWords.thisSession,
            messages: $chat.messages,
            isSending: isChatSending,
            suggestions: appModel.featureRegistry.contains(id: SuggestedQuestionsFeatureModule.id) ? SuggestedQuestions.session : [],
            onSend: chat.send,
            onStop: { chat.stop() },
            queuedStatus: chatRunner.queuedStatus,
            notices: chat.notices,
            onCompact: { chat.compact($0) },
            progress: chatRunner.progress,
            effort: $settings.sessionChatEffort,
            isSessionRecording: recorder.isRecording,
            returnedQuestion: $chat.returnedQuestion
        )
    }

    /// Puts this session first for a summary, if it needs one (too long to send
    /// whole, or its patient's history is) and has none. The scheduler builds
    /// it when nothing else is using the model (`DigestScheduler`).
    private func ensureDigest() {
        guard transcriptReadError == nil, !transcriptText.isEmpty else { return }
        integrations.digestScheduler.sessionOpened(patient: patient, session: session)
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
        if let refusal = recorder.startRefusal() {
            errorMessage = refusal
            return
        }
        guard !appModel.needsRecordingConsent(patient: patient, session: session) else {
            consentPurpose = .record
            showRecordingConsent = true
            return
        }
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

    private func requestAudioImport() {
        switch appModel.beginAudioImport(patient: patient, session: session) {
        case .blocked: return
        case .refused(let message): errorMessage = message
        case .needsConsent:
            consentPurpose = .importAudio
            showRecordingConsent = true
        case .ready: pickAudioFile()
        }
    }

    private func pickAudioFile() {
        #if DEBUG
        // A UI test cannot answer the system open panel; a fixture run hands
        // over its own clip instead.
        if let fixture = FixtureMode.importFiles() {
            importAudio(from: fixture)
            return
        }
        #endif
        showAudioImporter = true
    }

    /// Converts and seals the picked files off the main thread, then transcribes
    /// them when "Transcribe automatically" is on, as a finished recording would be.
    private func importAudio(from urls: [URL]) {
        guard let store = appModel.store else { return }
        isImportingAudio = true
        let patient = patient, session = session
        Task {
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do {
                    try store.importRecordings(from: urls, for: patient, session: session)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            isImportingAudio = false
            onSessionUpdated()
            if let failure {
                errorMessage = failure
            } else if settings.autoTranscribeAfterRecording {
                transcription.start(patient: patient, session: session)
            }
        }
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
        if note.sessionHasSigned {
            return "A note for this session is signed. Reopen it as a draft before transcribing again."
        }
        return SessionActionPolicy.transcribeBlocker(
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


    private func editComment(_ comment: SessionComment, _ body: String) {
        guard let commentStore = appModel.commentStore,
              CommentsRailView.canSaveEdit(draft: body, original: comment.body) else { return }
        appModel.updateComment(id: comment.id, body: body)
        allComments = commentStore.comments(sessionID: session.id)
    }

    private func deleteComment(_ comment: SessionComment) {
        guard let commentStore = appModel.commentStore else { return }
        commentStore.deleteComment(id: comment.id)
        allComments = commentStore.comments(sessionID: session.id)
    }

    private func showAlert(_ alert: AIAlert) {
        switch alert {
        case .message(let text):
            errorMessage = text
        case .engine(let incident, let kind, let retry):
            engineRetries.set(retry, for: kind)
            engineIncident = incident
        }
    }

    private func load() {
        guard let store = appModel.store else { return }
        refreshConsent()
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
        note.configure(
            appModel: appModel, integrations: integrations, settings: settings,
            patient: patient, session: session, material: material)
        note.sessionUpdated = onSessionUpdated
        note.alert = showAlert
        chat.configure(
            appModel: appModel, integrations: integrations, settings: settings,
            patient: patient, session: session, material: material)
        chat.alert = showAlert
        note.showSaved(for: settings.progressNoteFormat)
        chat.load()
        if let commentStore = appModel.commentStore {
            let storedNote = commentStore.note(sessionID: session.id)
            persistedSessionNote = storedNote
            sessionNote = storedNote
            allComments = commentStore.comments(sessionID: session.id)
        }
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
