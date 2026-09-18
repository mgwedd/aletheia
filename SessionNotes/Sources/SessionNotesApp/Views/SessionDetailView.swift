import SwiftUI

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
    @State private var newCommentQuote: String = ""
    @State private var newCommentBody: String = ""
    @State private var isTranscribing = false
    @State private var transcribeProgress: Double = 0
    @State private var isSummarizing = false
    @State private var isChatSending = false
    @StateObject private var chatRunner = ChatStreamRunner()
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
            TabView {
                transcriptTab.tabItem { Label("Transcript", systemImage: "text.alignleft") }
                notesTab.tabItem { Label("Notes", systemImage: "square.and.pencil") }
                commentsTab.tabItem { Label("Comments", systemImage: "bubble.left") }
                summaryTab.tabItem { Label("Summary", systemImage: "doc.text") }
                chatTab.tabItem { Label("Ask", systemImage: "bubble.left.and.bubble.right") }
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
                HStack {
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
                ScrollView {
                    Text(transcriptText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
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
                    appModel.commentStore?.saveNote(patientSlug: patient.slug, sessionFolder: session.folderName, text: newValue)
                }
        }
    }

    private var commentsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add a comment")
                    .font(.body.weight(.medium))
                TextField("Passage this is about (optional)", text: $newCommentQuote)
                    .textFieldStyle(.roundedBorder)
                TextField("Your comment", text: $newCommentBody, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                HStack {
                    Spacer()
                    Button("Add Comment", action: addComment)
                        .buttonStyle(.borderedProminent)
                        .disabled(newCommentBody.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding([.horizontal, .top])

            Divider()

            if comments.isEmpty {
                ContentUnavailableView("No Comments Yet", systemImage: "bubble.left", description: Text("Comments you add are included when you ask about this session."))
            } else {
                List {
                    ForEach(comments) { comment in
                        VStack(alignment: .leading, spacing: 4) {
                            if !comment.quotedText.isEmpty {
                                Text("“\(comment.quotedText)”")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .italic()
                            }
                            Text(comment.body)
                            HStack {
                                Spacer()
                                Button(role: .destructive) { deleteComment(comment) } label: {
                                    Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var summaryTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    Task { await summarize() }
                } label: {
                    if isSummarizing {
                        Label("Summarizing…", systemImage: "sparkles")
                    } else {
                        Label("Summarize with AI", systemImage: "sparkles")
                    }
                }
                .disabled(transcriptText.isEmpty || isSummarizing)
                Spacer()
            }
            .padding([.horizontal, .top])

            if !summaryText.isEmpty {
                Text("AI-generated. Always read alongside the transcript before relying on it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            if summaryText.isEmpty {
                ContentUnavailableView("No Summary Yet", systemImage: "doc.text", description: Text("Transcribe the session first, then generate a summary."))
            } else {
                ScrollView {
                    Text(summaryText)
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
            sessionNote = commentStore.note(patientSlug: patient.slug, sessionFolder: session.folderName)
            comments = commentStore.comments(patientSlug: patient.slug, sessionFolder: session.folderName)
        }
    }

    private func addComment() {
        guard let commentStore = appModel.commentStore else { return }
        let body = newCommentBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        _ = commentStore.addComment(
            patientSlug: patient.slug,
            sessionFolder: session.folderName,
            quotedText: newCommentQuote.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body
        )
        newCommentQuote = ""
        newCommentBody = ""
        comments = commentStore.comments(patientSlug: patient.slug, sessionFolder: session.folderName)
    }

    private func deleteComment(_ comment: SessionComment) {
        guard let commentStore = appModel.commentStore else { return }
        commentStore.deleteComment(id: comment.id)
        comments = commentStore.comments(patientSlug: patient.slug, sessionFolder: session.folderName)
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
            appModel.refreshPatients()
            onSessionUpdated()
            await integrations.makeNotifier().post(
                SessionNotifications.transcriptionComplete(patientName: patient.name, date: session.date)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func summarize() async {
        guard let store = appModel.store else { return }
        isSummarizing = true
        defer { isSummarizing = false }
        do {
            let result = try await integrations.makeAssistantService().summarize(transcript: transcriptText)
            summaryText = result
            try store.saveSummary(result, for: patient, session: session)
            onSessionUpdated()
            await integrations.makeNotifier().post(
                SessionNotifications.summaryReady(patientName: patient.name, date: session.date)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
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
