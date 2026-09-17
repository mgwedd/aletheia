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
    @StateObject private var recorder = SessionRecorder()

    @State private var transcriptText: String = ""
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
    }

    private var header: some View {
        HStack(spacing: 16) {
            if recorder.isRecording {
                Button(role: .destructive) {
                    Task { await stopRecording() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                }
                Text("Recording…").foregroundStyle(.red)
            } else {
                Button {
                    Task { await startRecording() }
                } label: {
                    Label("Record Session", systemImage: "record.circle")
                }
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
            .disabled(recorder.isRecording || isTranscribing || !hasAnyRecording)

            Button {
                exportSession()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(transcriptText.isEmpty && summaryText.isEmpty)

            Menu {
                ForEach(ReminderLeadTime.allCases) { leadTime in
                    Button(leadTime.displayName) { Task { await scheduleReminder(leadTime) } }
                }
            } label: {
                Label("Remind Me", systemImage: "bell")
            }
            .menuIndicator(.hidden)
            .help("Add a follow-up reminder to your Reminders app")

            Button {
                scheduleStart = SessionEventBuilder.suggestedStart()
                scheduleDurationMinutes = SessionEventBuilder.defaultDurationMinutes
                showScheduleSheet = true
            } label: {
                Label("Schedule Next…", systemImage: "calendar.badge.plus")
            }
            .help("Add the next session to your Calendar")

            Spacer()
        }
        .padding()
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
        VStack(alignment: .leading) {
            if transcriptText.isEmpty {
                ContentUnavailableView("No Transcript Yet", systemImage: "text.alignleft", description: Text("Record a session, then tap Transcribe."))
            } else {
                ScrollView {
                    Text(transcriptText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
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

    private func startRecording() async {
        guard let store = appModel.store else { return }
        let micURL = store.micRecordingURL(for: patient, session: session)
        let callURL = store.callRecordingURL(for: patient, session: session)
        await recorder.start(micURL: micURL, callURL: callURL)
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
            let text = try await transcriber.transcribeSession(micURL: micURL, callURL: callURL) { progress in
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
