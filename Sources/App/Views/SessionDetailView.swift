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
    @State private var summaryText: String = ""
    @State private var chatMessages: [ChatMessage] = []
    @State private var sessionNote: String = ""
    // Editing the generated note (selected format only; Save/Cancel, no autosave).
    @State private var isEditingNote = false
    @State private var noteDraft = ""
    @State private var confirmRegenerate = false
    @State private var hasPreviousNote = false
    /// The note text as last read from / written to the store. `load()` assigns
    /// `sessionNote` programmatically, which fires `onChange`; comparing against
    /// this keeps that echo (and any no-op change) from being saved back.
    @State private var persistedSessionNote: String = ""
    @State private var comments: [SessionComment] = []
    /// The passage currently selected in the transcript view (empty = just a
    /// caret), driving the "Comment on selection" affordance.
    @State private var transcriptSelection = ""
    /// Where that selection sits in the transcript (UTF-16), nil for a caret.
    @State private var transcriptSelectionRange: NSRange?
    /// The passage and its start offset, frozen when the comment is begun so
    /// the composer sheet opening (or the selection changing) can't move what
    /// the comment gets anchored to.
    @State private var pendingQuote = ""
    @State private var pendingQuoteStart: Int?
    @State private var showInlineComposer = false
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
    /// Set when the last transcription came back blank and the recording was
    /// kept (see `AudioRetentionPolicy.decision`); shown inline, not as an alert.
    @State private var noSpeechNotice: String?
    @State private var isChatSending = false
    @StateObject private var chatRunner = ChatStreamRunner()
    @StateObject private var noteRunner = ChatStreamRunner()
    @State private var errorMessage: String?
    @State private var confirmationMessage: String?
    @State private var showScheduleSheet = false
    @State private var scheduleStart = Date()
    @State private var scheduleDurationMinutes = SessionEventBuilder.defaultDurationMinutes

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            TabView(selection: $selectedTab) {
                transcriptTab.tabItem { Label("Transcript", systemImage: "text.alignleft") }.tag(SessionTab.transcript)
                notesTab.tabItem { Label("Notes", systemImage: "doc.text") }.tag(SessionTab.notes)
                chatTab.tabItem { Label("Ask", systemImage: "bubble.left.and.bubble.right") }.tag(SessionTab.ask)
            }
        }
        .navigationTitle(Self.dateFormatter.string(from: session.date))
        .onAppear {
            load()
            // A transcription that finished while this screen was away.
            consumeTranscriptionOutcome()
        }
        .onDisappear {
            // Navigation that couldn't ask first (another patient, a search hit):
            // keep the unsaved edits for the next time this session opens.
            UnsavedTranscriptDrafts.stash(transcriptDraft, saved: transcriptText, for: session.id)
            editGuard?.detach()
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
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Done", isPresented: Binding(get: { confirmationMessage != nil }, set: { if !$0 { confirmationMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(confirmationMessage ?? "")
        }
        .sheet(isPresented: $showScheduleSheet) { scheduleSheet }
        .onChange(of: recorder.longRunningReminder) { _, exceeded in
            // Also fire a system notification so it's noticed if the app isn't
            // focused (the therapist has likely switched to the call window).
            if exceeded {
                let name = recorder.active?.patientName ?? patient.name
                Task {
                    await integrations.makeNotifier().post(
                        SessionNotifications.longRecordingReminder(patientName: name)
                    )
                }
            }
        }
        .alert("Still recording", isPresented: recorderReminderBinding) {
            Button("Keep Recording", role: .cancel) {}
            Button("Stop Now", role: .destructive) { Task { await stopRecording() } }
        } message: {
            Text("This session has been recording for over 90 minutes. Did you forget to end it?")
        }
    }

    private var recorderReminderBinding: Binding<Bool> {
        Binding(
            // Only the view of the session actually recording shows the alert.
            get: { recorder.longRunningReminder && isRecordingThisSession },
            set: { if !$0 { recorder.longRunningReminder = false } }
        )
    }

    private var header: some View {
        HStack(spacing: 16) {
            // Show full labels when the window is wide enough; fall back to
            // icon-only buttons (each keeps a .help tooltip) when it isn't, so
            // the labels never overflow or truncate. ViewThatFits picks the
            // first layout whose ideal width fits the available space.
            ViewThatFits(in: .horizontal) {
                headerControls.labelStyle(.titleAndIcon)
                headerControls.labelStyle(.iconOnly)
            }
            Spacer(minLength: 0)
        }
        .padding()
    }

    private var headerControls: some View {
        HStack(spacing: 16) {
            if isRecordingThisSession {
                Button(role: .destructive) {
                    Task { await stopRecording() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                }
                .help("Stop recording this session")
                if recorder.isPaused {
                    Button { recorder.resume() } label: {
                        Label("Resume", systemImage: "play.circle")
                    }
                    .help("Resume recording")
                } else {
                    Button { recorder.pause() } label: {
                        Label("Pause", systemImage: "pause.circle")
                    }
                    .help("Pause recording")
                }
                Image(systemName: recorder.isPaused ? "pause.circle.fill" : "record.circle.fill")
                    .foregroundStyle(recorder.isPaused ? .orange : .red)
                    .symbolEffect(.pulse, options: recorder.isPaused ? .nonRepeating : .repeating)
                    .help(recorder.isPaused ? "Paused" : "Recording…")
            } else if recorder.isRecording {
                // A different session is recording (via the menu bar); don't let
                // this view start a second one or stop the other by surprise.
                Label("Recording another session", systemImage: "record.circle")
                    .foregroundStyle(.secondary)
                    .help("Stop the current recording from the menu bar first")
            } else {
                Button {
                    Task { await startRecording() }
                } label: {
                    Label("Record Session", systemImage: "record.circle")
                }
                .help(isTranscribing ? "Finish transcribing first" : "Record this session's audio")
                .disabled(isTranscribing)
            }

            Divider().frame(height: 20)

            // The label stays put; a spinner beside it shows work is under way
            // (the progress itself lives in the Transcript tab).
            Button {
                noSpeechNotice = nil
                transcription.start(patient: patient, session: session)
            } label: {
                Label("Transcribe", systemImage: "waveform")
            }
            .help(transcription.isBusy && !isTranscribing
                  ? "Another session is being transcribed"
                  : "Transcribe the recorded audio on-device")
            .disabled(recorder.isRecording || transcription.isBusy || !hasAnyRecording)
            if isTranscribing {
                ProgressView().controlSize(.small)
            }

            Button {
                exportSession()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export this session to Markdown")
            .disabled(transcriptText.isEmpty && summaryText.isEmpty)

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
                    showScheduleSheet = true
                } label: {
                    Label("Schedule Next…", systemImage: "calendar.badge.plus")
                }
                .help("Add the next session to your Calendar")
            }
        }
    }

    private func scheduleReminder(_ leadTime: ReminderLeadTime) async {
        let draft = SessionReminderBuilder.draft(
            patientName: patient.name,
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
            patientName: patient.name,
            start: scheduleStart,
            durationMinutes: scheduleDurationMinutes
        )
        do {
            try await integrations.makeCalendarScheduler().schedule(draft)
            showScheduleSheet = false
            confirmationMessage = "Added “\(draft.title)” to your Calendar."
        } catch {
            showScheduleSheet = false
            errorMessage = error.localizedDescription
        }
    }

    private var scheduleSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Schedule Next Session").font(.headline)
            DatePicker("Date & time", selection: $scheduleStart)
                .datePickerStyle(.compact)
            Stepper("Duration: \(scheduleDurationMinutes) minutes", value: $scheduleDurationMinutes, in: 15...120, step: 5)
            HStack {
                Spacer()
                Button("Cancel") { showScheduleSheet = false }
                Button("Add to Calendar") { Task { await scheduleEvent() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func exportSession() {
        guard let store = appModel.store else { return }
        let markdown = store.exportSessionMarkdown(patient: patient, session: session)
        let dateStr = String(session.folderName.prefix(10))
        let name = FileSaver.fileName(patient.name, dateStr) + ".md"
        FileSaver.saveText(markdown, suggestedName: name)
    }

    private var hasAnyRecording: Bool {
        guard let store = appModel.store else { return false }
        let mic = store.micRecordingURL(for: patient, session: session)
        let call = store.callRecordingURL(for: patient, session: session)
        return FileManager.default.fileExists(atPath: mic.path) || FileManager.default.fileExists(atPath: call.path)
    }

    private var transcriptTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let job = transcription.job(for: session.id) {
                TranscriptionProgressView(job: job, compact: !transcriptText.isEmpty) {
                    transcription.cancel(sessionID: session.id)
                }
            }
            if let notice = noSpeechNotice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(notice)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Dismiss") { noSpeechNotice = nil }
                        .buttonStyle(.borderless)
                }
                .font(.callout)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding([.horizontal, .top])
            }
            if transcriptText.isEmpty && transcriptDraft.isEmpty && !hasTranscript {
                // While transcribing, the progress card above is the pane.
                if !isTranscribing {
                    ContentUnavailableView("No Transcript Yet", systemImage: "text.alignleft", description: Text("Record a session, then tap Transcribe."))
                }
            } else {
                if let readError = transcriptReadError {
                    Label("This transcript couldn't be read, so editing is turned off to avoid overwriting it. \(readError)", systemImage: "lock")
                        .font(.callout)
                        .padding([.horizontal, .top])
                }
                HStack(spacing: 8) {
                    Button {
                        beginInlineComment()
                    } label: {
                        Label("Comment on Selection", systemImage: "text.bubble")
                    }
                    .disabled(transcriptSelection.isEmpty || transcriptIsDirty)
                    .help(transcriptIsDirty
                          ? "Save or discard your transcript edits before adding a comment"
                          : transcriptSelection.isEmpty
                          ? "Select a passage in the transcript to comment on it"
                          : "Add a comment on the selected passage")
                    Spacer()
                    if transcriptIsDirty {
                        Label("Unsaved changes", systemImage: "pencil")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("Discard") { showDiscardConfirm = true }
                        .disabled(!transcriptIsDirty)
                        .help("Throw away your unsaved edits")
                    Button("Save") { saveTranscriptDraft() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!transcriptIsDirty || transcriptReadError != nil)
                        .help("Save your edits to the transcript")
                }
                .padding([.horizontal, .top])
                // Google-Docs layout: the transcript on the left, its comments in
                // a margin rail on the right. Only *unresolved* comments carry a
                // highlight in the text; the rail keeps resolved ones tucked away.
                // The view edits the draft, and highlights follow it.
                HStack(spacing: 0) {
                    TranscriptTextView(
                        text: $transcriptDraft,
                        isEditable: transcriptReadError == nil,
                        comments: activeAnchors,
                        selection: $transcriptSelection,
                        selectionRange: $transcriptSelectionRange,
                        onOpenComment: openComment,
                        focusedCommentID: focusedCommentID,
                        focusToken: focusToken
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
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
                }
            }
        }
        .confirmationDialog("Discard your unsaved edits?", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Discard Edits", role: .destructive) { discardTranscriptEdits() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("The transcript goes back to the last saved version.")
        }
        .sheet(isPresented: $showInlineComposer) { inlineComposer }
    }

    /// The composer shown after selecting a transcript passage: the quoted text
    /// is fixed (it's what you selected), you just write the note.
    private var inlineComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comment on passage").font(.headline)
            Text("“\(pendingQuote)”")
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            EditorField(text: $inlineCommentBody, placeholder: "Add a comment…", minHeight: 90)
                .frame(maxHeight: 160)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showInlineComposer = false }
                Button("Add Comment") { saveInlineComment() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(inlineCommentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 440)
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
        inlineCommentBody = ""
        showInlineComposer = true
    }

    private func saveInlineComment() {
        guard let commentStore = appModel.commentStore else { return }
        let quote = pendingQuote
        let body = inlineCommentBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty, !body.isEmpty else { return }
        // Time-stamp from the exact line selected when we know where it was;
        // searching for the quote text would land on its first occurrence.
        let anchorSecs: Int?
        if let start = pendingQuoteStart {
            anchorSecs = TranscriptTimeline.seconds(atOffset: start, in: transcriptText)
        } else {
            anchorSecs = TranscriptTimeline.seconds(forQuote: quote, in: transcriptText)
        }
        let created = commentStore.addComment(
            sessionID: session.id,
            quotedText: quote,
            body: body,
            anchorSeconds: anchorSecs.map { Double($0) },
            quoteStart: pendingQuoteStart
        )
        comments = commentStore.comments(sessionID: session.id)
        showInlineComposer = false
        // Bring the new card into view in the rail.
        if let id = created?.id {
            focusComment(id)
        } else {
            focusedCommentID = nil
        }
    }

    /// Requests focus on a comment: highlights its card, scrolls the card into
    /// view in the rail, and scrolls-and-flashes its passage in the transcript.
    /// Bumping the token makes each request an event, so asking for the
    /// already-focused comment again (after scrolling away) works too.
    private func focusComment(_ id: String) {
        focusedCommentID = id
        focusToken += 1
    }

    /// Clicking a highlighted passage focuses its card in the margin rail (and
    /// scrolls it into view) — no tab change, since the rail is right there.
    private func openComment(_ id: String) {
        focusComment(id)
    }

    private func resolveComment(_ comment: SessionComment, _ resolved: Bool) {
        guard let commentStore = appModel.commentStore else { return }
        commentStore.setCommentResolved(id: comment.id, resolved: resolved)
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
        onSessionUpdated()
        return true
    }

    private func discardTranscriptEdits() {
        transcriptDraft = transcriptText
    }

    private var myNotesView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your own notes for this session — jot things down during or after the session. Kept separate from the transcript, and included when you ask about this session.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding([.horizontal, .top])
            EditorField(
                text: $sessionNote,
                placeholder: "Jot things down during or after the session…",
                minHeight: 160,
                fills: true
            )
            .padding([.horizontal, .bottom])
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
        VStack(alignment: .leading, spacing: 0) {
            Picker("Notes", selection: notesPaneBinding) {
                ForEach(NotesPane.all) { pane in
                    Text(pane.label).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(noteRunner.isStreaming || noteRunner.isQueued || isEditingNote)
            .padding([.horizontal, .top])

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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(settings.progressNoteFormat.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    if noteRunner.isStreaming {
                        Button(role: .destructive) { noteRunner.stop() } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    } else if noteRunner.isQueued {
                        // Waiting behind another generation: offer to back out
                        // rather than a Generate button that looks stuck.
                        Button(role: .cancel) { noteRunner.stop() } label: {
                            Label("Cancel", systemImage: "xmark")
                        }
                    } else {
                        Button {
                            requestGenerateNote()
                        } label: {
                            Label(summaryText.isEmpty ? "Generate note" : "Regenerate", systemImage: "sparkles")
                        }
                        .keyboardShortcut("g", modifiers: .command)
                        .disabled(transcriptText.isEmpty || isEditingNote)
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
                            copyToPasteboard(summaryText)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .help("Copy the note to paste into your EHR")
                    }
                }
                if let status = noteRunner.queuedStatus {
                    Label(status, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .top])

            if noteIsOutdated {
                OutdatedNoteBanner(canRegenerate: !transcriptText.isEmpty, onRegenerate: generateNote)
            }

            if !summaryText.isEmpty {
                Text("AI-drafted from the transcript and your notes. Review and edit before it goes in the record.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            if summaryText.isEmpty && !noteRunner.isStreaming {
                ContentUnavailableView(
                    "No Note Yet",
                    systemImage: "doc.text",
                    description: Text("There's no \(settings.progressNoteFormat.shortName) note for this session yet. Transcribe the session, then generate one.")
                )
            } else if isEditingNote {
                HStack {
                    Label("Editing the \(settings.progressNoteFormat.shortName) note. Regenerating asks before replacing your edits.", systemImage: "pencil")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { isEditingNote = false }
                    Button("Save") { saveEditedNote() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!NoteEditing.canSave(draft: noteDraft, original: summaryText))
                }
                .padding(.horizontal)
                EditorField(text: $noteDraft, minHeight: 200, fills: true)
                    .padding([.horizontal, .bottom])
            } else {
                ScrollView {
                    MarkdownMessageView(text: summaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        // Each format keeps its own note, so the pane follows the picker.
        .onChange(of: settings.progressNoteFormat) { _, newFormat in
            isEditingNote = false
            summaryText = savedNote(for: newFormat)
            noteFingerprint = savedFingerprint(for: newFormat)
            refreshHasPreviousNote()
        }
        .alert("Replace your edited note?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) { generateNote() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You edited this \(settings.progressNoteFormat.shortName) note. Regenerating replaces it; your edited version is kept and can be brought back with Restore Previous.")
        }
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
        if NoteEditing.shouldArchiveBeforeReplacing(state) {
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

    private func refreshHasPreviousNote() {
        guard let store = appModel.store else { hasPreviousNote = false; return }
        hasPreviousNote = store.previousNote(for: patient, session: session, format: settings.progressNoteFormat) != nil
    }

    private var chatTab: some View {
        ChatPaneView(title: "this session", messages: $chatMessages, isSending: isChatSending, suggestions: appModel.featureRegistry.contains(id: SuggestedQuestionsFeatureModule.id) ? SuggestedQuestions.session : [], onSend: sendChat, onStop: { chatRunner.stop() }, queuedStatus: chatRunner.queuedStatus)
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
        commentStore.updateComment(id: comment.id, body: body)
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
        guard let store = appModel.store else { return }
        let micURL = store.micRecordingURL(for: patient, session: session)
        let callURL = store.callRecordingURL(for: patient, session: session)
        await recorder.start(
            micURL: micURL,
            callURL: callURL,
            context: .init(
                patientID: patient.id,
                patientName: patient.name,
                patientSlug: patient.slug,
                sessionFolder: session.folderName
            ),
            protector: appModel.currentProtector
        )
        if case .error(let message) = recorder.state {
            errorMessage = message
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
        let format = settings.progressNoteFormat
        // Snapshot the inputs now; the request itself is only made when the
        // queue starts this job (it may be waiting behind a chat answer).
        let service = integrations.makeAssistantService()
        let transcript = transcriptText
        let notes = sessionNote
        let sessionComments = comments
        noteRunner.start(
            queue: integrations.inferenceQueue,
            kind: .note,
            label: "progress note",
            makeStream: {
                service.streamProgressNote(
                    format: format,
                    transcript: transcript,
                    notes: notes,
                    comments: sessionComments
                )
            },
            onReveal: { text in
                if settings.progressNoteFormat == format { summaryText = text }
            },
            onError: { error in
                errorMessage = error.localizedDescription
                // The reveal blanked the pane; put back what is actually saved.
                if settings.progressNoteFormat == format { summaryText = savedNote(for: format) }
            },
            onFinish: { final in
                let trimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                if settings.progressNoteFormat == format { summaryText = final }
                do {
                    try store.saveGeneratedNote(final, for: patient, session: session, format: format, generatedFromTranscript: transcript)
                } catch {
                    errorMessage = error.localizedDescription
                    if settings.progressNoteFormat == format { summaryText = savedNote(for: format) }
                    return
                }
                // Record which transcript this note came from (the snapshot the
                // request used, not whatever the transcript is by now).
                if settings.progressNoteFormat == format {
                    refreshHasPreviousNote()
                    noteFingerprint = NoteFreshness.fingerprint(of: transcript)
                }
                onSessionUpdated()
                Task {
                    await integrations.makeNotifier().post(
                        SessionNotifications.summaryReady(patientName: patient.name, date: session.date)
                    )
                }
            }
        )
    }

    private func copyToPasteboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private func sendChat(_ question: String) {
        guard let store = appModel.store else { return }
        let userMessage = ChatMessage(role: .user, text: question)
        chatMessages.append(userMessage)
        isChatSending = true
        let assistantID = UUID()
        // Snapshot the inputs now; the request itself is only made when the
        // queue starts this job (it may be waiting behind the note).
        let service = integrations.makeAssistantService()
        let transcript = transcriptText
        let notes = sessionNote
        let sessionComments = comments
        let history = chatMessages
        chatRunner.start(
            queue: integrations.inferenceQueue,
            kind: .sessionChat,
            label: "session question",
            makeStream: {
                service.streamAnswerAboutSession(
                    transcript: transcript,
                    notes: notes,
                    comments: sessionComments,
                    history: history,
                    question: question
                )
            },
            onReveal: { text in chatMessages.upsert(id: assistantID, role: .assistant, text: text) },
            onError: { error in
                isChatSending = false
                errorMessage = error.localizedDescription
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
