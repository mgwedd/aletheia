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
    @State private var isTranscribing = false
    @State private var transcribeProgress: Double = 0
    @State private var isSummarizing = false
    @State private var isChatSending = false
    @State private var errorMessage: String?

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

            Spacer()
        }
        .padding()
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
        ChatPaneView(title: "this session", messages: $chatMessages, isSending: isChatSending, onSend: sendChat)
    }

    private func load() {
        guard let store = appModel.store else { return }
        transcriptText = store.transcript(for: patient, session: session) ?? ""
        summaryText = store.summary(for: patient, session: session) ?? ""
        chatMessages = store.loadSessionChat(for: patient, session: session)
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sendChat(_ question: String) {
        guard let store = appModel.store else { return }
        chatMessages.append(ChatMessage(role: .user, text: question))
        isChatSending = true
        Task {
            defer { isChatSending = false }
            do {
                let response = try await integrations.makeAssistantService()
                    .answerAboutSession(transcript: transcriptText, history: chatMessages, question: question)
                chatMessages.append(ChatMessage(role: .assistant, text: response))
                try? store.saveSessionChat(chatMessages, for: patient, session: session)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
