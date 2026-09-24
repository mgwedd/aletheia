import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The tabs in the session detail. Comments no longer have their own tab —
/// they live in a margin rail beside the transcript (Google-Docs style), so
/// the passage and its comments are read together.
enum SessionTab: Hashable {
    case transcript, notes, summary, ask
}

struct SessionDetailView: View {
    let patient: Patient
    let session: SessionRecord
    /// Called after recording, transcribing, or summarizing changes what's
    /// on disk for this session, so the sessions list (visible at the same
    /// time in the split view) can refresh its "has recording/transcript/
    /// summary" badges without the therapist needing to click away and back.
    var onSessionUpdated: () -> Void = {}

    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations
    @EnvironmentObject private var settings: AppSettings
    // Shared with the menu-bar control (injected at app level) so both drive the
    // same recording. "Recording" in this view means *this* session specifically.
    @EnvironmentObject private var recorder: SessionRecorder

    @State private var transcriptText: String = ""
    @State private var isEditingTranscript = false
    @State private var transcriptDraft = ""
    @State private var summaryText: String = ""
    @State private var chatMessages: [ChatMessage] = []
    @State private var sessionNote: String = ""
    @State private var comments: [SessionComment] = []
    /// The passage currently selected in the transcript view (empty = just a
    /// caret), driving the "Comment on selection" affordance.
    @State private var transcriptSelection = ""
    @State private var showInlineComposer = false
    @State private var inlineCommentBody = ""
    @State private var selectedTab: SessionTab = .transcript
    /// The comment currently in focus — drives the two-way highlight between a
    /// transcript passage and its card in the margin rail. Set by clicking
    /// either side.
    @State private var focusedCommentID: String?
    @State private var isTranscribing = false
    @State private var transcribeProgress: Double = 0
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
                notesTab.tabItem { Label("Notes", systemImage: "square.and.pencil") }.tag(SessionTab.notes)
                summaryTab.tabItem { Label("Note", systemImage: "doc.text") }.tag(SessionTab.summary)
                chatTab.tabItem { Label("Ask", systemImage: "bubble.left.and.bubble.right") }.tag(SessionTab.ask)
            }
        }
        .navigationTitle(Self.dateFormatter.string(from: session.date))
        .onAppear(perform: load)
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
                .help("Record this session's audio")
                .disabled(isTranscribing)
            }

            Divider().frame(height: 20)

            Button {
                Task { await transcribe() }
            } label: {
                if isTranscribing {
                    Label("Transcribing… \(Int(transcribeProgress * 100))%", systemImage: "waveform")
                } else {
                    Label("Transcribe", systemImage: "waveform")
                }
            }
            .help("Transcribe the recorded audio on-device")
            .disabled(recorder.isRecording || isTranscribing || !hasAnyRecording)

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
            if transcriptText.isEmpty && !isEditingTranscript {
                ContentUnavailableView("No Transcript Yet", systemImage: "text.alignleft", description: Text("Record a session, then tap Transcribe."))
            } else if isEditingTranscript {
                HStack {
                    Label("Editing the transcript — this is the source of truth used for summaries and chat.", systemImage: "pencil")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { isEditingTranscript = false }
                    Button("Save") { saveEditedTranscript() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding([.horizontal, .top])
                TextEditor(text: $transcriptDraft)
                    .font(.body.monospaced())
                    .padding(8)
            } else {
                HStack(spacing: 8) {
                    Button {
                        beginInlineComment()
                    } label: {
                        Label("Comment on Selection", systemImage: "text.bubble")
                    }
                    .disabled(transcriptSelection.isEmpty)
                    .help(transcriptSelection.isEmpty
                          ? "Select a passage in the transcript to comment on it"
                          : "Add a comment on the selected passage")
                    Spacer()
                    Button {
                        transcriptDraft = transcriptText
                        isEditingTranscript = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .help("Correct the transcript or remove sensitive content")
                }
                .padding([.horizontal, .top])
                // Google-Docs layout: the transcript on the left, its comments in
                // a margin rail on the right. Only *unresolved* comments carry a
                // highlight in the text; the rail keeps resolved ones tucked away.
                HStack(spacing: 0) {
                    TranscriptTextView(
                        transcript: transcriptText,
                        comments: comments.filter { !$0.resolved }.map { (id: $0.id, quote: $0.quotedText) },
                        selection: $transcriptSelection,
                        onOpenComment: openComment,
                        focusedCommentID: focusedCommentID
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    CommentsRailView(
                        comments: comments,
                        focusedCommentID: $focusedCommentID,
                        onResolve: resolveComment,
                        onDelete: deleteComment
                    )
                }
            }
        }
        .sheet(isPresented: $showInlineComposer) { inlineComposer }
    }

    /// The composer shown after selecting a transcript passage: the quoted text
    /// is fixed (it's what you selected), you just write the note.
    private var inlineComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comment on passage").font(.headline)
            Text("“\(transcriptSelection)”")
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            TextEditor(text: $inlineCommentBody)
                .font(.body)
                .frame(minHeight: 90, maxHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
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

    private func beginInlineComment() {
        inlineCommentBody = ""
        showInlineComposer = true
    }

    private func saveInlineComment() {
        guard let commentStore = appModel.commentStore else { return }
        let quote = transcriptSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = inlineCommentBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty, !body.isEmpty else { return }
        let anchor = TranscriptTimeline.seconds(forQuote: quote, in: transcriptText).map { Double($0) }
        let created = commentStore.addComment(
            sessionID: session.id,
            quotedText: quote,
            body: body,
            anchorSeconds: anchor
        )
        comments = commentStore.comments(sessionID: session.id)
        showInlineComposer = false
        // Bring the new card into view in the rail.
        focusedCommentID = created?.id
    }

    /// Clicking a highlighted passage focuses its card in the margin rail (and
    /// scrolls it into view) — no tab change, since the rail is right there.
    private func openComment(_ id: String) {
        focusedCommentID = id
    }

    private func resolveComment(_ comment: SessionComment, _ resolved: Bool) {
        guard let commentStore = appModel.commentStore else { return }
        commentStore.setCommentResolved(id: comment.id, resolved: resolved)
        comments = commentStore.comments(sessionID: session.id)
        // A resolved comment loses its highlight; don't keep focusing it.
        if resolved, focusedCommentID == comment.id { focusedCommentID = nil }
    }

    private func saveEditedTranscript() {
        guard let store = appModel.store else { return }
        do {
            try store.saveTranscript(transcriptDraft, for: patient, session: session)
            transcriptText = transcriptDraft
            isEditingTranscript = false
            onSessionUpdated()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var notesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your private notes for this session — jot things down during or after the session. Kept separate from the transcript, and included when you ask about this session.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding([.horizontal, .top])
            TextEditor(text: $sessionNote)
                .font(.body)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
                .onChange(of: sessionNote) { _, newValue in
                    appModel.commentStore?.saveNote(sessionID: session.id, text: newValue)
                }
        }
    }

    private var summaryTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Format", selection: $settings.progressNoteFormat) {
                    ForEach(ProgressNoteFormat.allCases) { format in
                        Text(format.shortName).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(noteRunner.isStreaming)

                HStack(alignment: .firstTextBaseline) {
                    Text(settings.progressNoteFormat.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    if noteRunner.isStreaming {
                        Button(role: .destructive) { noteRunner.stop() } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    } else {
                        Button {
                            generateNote()
                        } label: {
                            Label(summaryText.isEmpty ? "Generate note" : "Regenerate", systemImage: "sparkles")
                        }
                        .keyboardShortcut("g", modifiers: .command)
                        .disabled(transcriptText.isEmpty)
                    }
                    if !summaryText.isEmpty && !noteRunner.isStreaming {
                        Button {
                            copyToPasteboard(summaryText)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .help("Copy the note to paste into your EHR")
                    }
                }
            }
            .padding([.horizontal, .top])

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
                    description: Text("Transcribe the session, pick a format, then generate a \(settings.progressNoteFormat.shortName) note.")
                )
            } else {
                ScrollView {
                    MarkdownMessageView(text: summaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
    }

    private var chatTab: some View {
        ChatPaneView(title: "this session", messages: $chatMessages, isSending: isChatSending, suggestions: SuggestedQuestions.session, onSend: sendChat, onStop: { chatRunner.stop() })
    }

    private func load() {
        guard let store = appModel.store else { return }
        transcriptText = store.transcript(for: patient, session: session) ?? ""
        summaryText = store.summary(for: patient, session: session) ?? ""
        chatMessages = store.loadSessionChat(for: patient, session: session)
        if let commentStore = appModel.commentStore {
            sessionNote = commentStore.note(sessionID: session.id)
            comments = commentStore.comments(sessionID: session.id)
        }
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

    private func transcribe() async {
        guard let store = appModel.store else { return }
        isTranscribing = true
        transcribeProgress = 0
        defer { isTranscribing = false }
        // Ask in context: transcription can take minutes, and we want to tell
        // her when it's done if she's stepped away.
        await integrations.makeNotifier().requestAuthorization()
        do {
            let transcriber = integrations.makeTranscriber()
            let micURL = store.micRecordingURL(for: patient, session: session)
            let callURL = store.callRecordingURL(for: patient, session: session)
            // If the recordings are sealed, decrypt them to temporary files for
            // the resampler (which needs a real, seekable audio file), and clean
            // the plaintext copies up afterwards.
            let protector = appModel.currentProtector
            let (micReadURL, micIsTemp) = try protector.decryptedCopyOfLargeFile(at: micURL)
            let (callReadURL, callIsTemp) = try protector.decryptedCopyOfLargeFile(at: callURL)
            defer {
                if micIsTemp { try? FileManager.default.removeItem(at: micReadURL) }
                if callIsTemp { try? FileManager.default.removeItem(at: callReadURL) }
            }
            let text = try await transcriber.transcribeSession(micURL: micReadURL, callURL: callReadURL) { progress in
                Task { @MainActor in transcribeProgress = progress }
            }
            transcriptText = text
            try store.saveTranscript(text, for: patient, session: session)
            // Transcript-only by default: discard the raw audio now that the
            // transcript (the document of record) is saved. Audio is kept only
            // when the user opted in *and* at-rest encryption is on, so anything
            // retained on disk is ciphertext, never plaintext PHI. The gate is
            // enforced here on behavior, not just in the UI, so stale settings or
            // encryption being turned off can't leave audio in the clear.
            if AudioRetentionPolicy.discardsAudioAfterTranscription(
                optedIn: settings.keepAudioRecordings,
                encryptionEnabled: appModel.isEncryptionEnabled
            ) {
                store.deleteRecordings(for: patient, session: session)
            }
            appModel.refreshPatients()
            onSessionUpdated()
            await integrations.makeNotifier().post(
                SessionNotifications.transcriptionComplete(patientName: patient.name, date: session.date)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Streams a clinical progress note (in the selected format) into the
    /// summary view as it writes, then persists the finished note. Reuses the
    /// same calm word-by-word reveal as chat, with a working Stop.
    private func generateNote() {
        guard let store = appModel.store else { return }
        let stream = integrations.makeAssistantService().streamProgressNote(
            format: settings.progressNoteFormat,
            transcript: transcriptText,
            notes: sessionNote,
            comments: comments
        )
        noteRunner.start(
            stream: stream,
            onReveal: { text in summaryText = text },
            onError: { error in errorMessage = error.localizedDescription },
            onFinish: { final in
                let trimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                summaryText = final
                try? store.saveSummary(final, for: patient, session: session)
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
        chatMessages.append(ChatMessage(role: .user, text: question))
        isChatSending = true
        let assistantID = UUID()
        let stream = integrations.makeAssistantService()
            .streamAnswerAboutSession(
                transcript: transcriptText,
                notes: sessionNote,
                comments: comments,
                history: chatMessages,
                question: question
            )
        chatRunner.start(
            stream: stream,
            onReveal: { text in chatMessages.upsert(id: assistantID, role: .assistant, text: text) },
            onError: { error in
                isChatSending = false
                errorMessage = error.localizedDescription
            },
            onFinish: { _ in
                isChatSending = false
                try? store.saveSessionChat(chatMessages, for: patient, session: session)
            }
        )
    }
}
