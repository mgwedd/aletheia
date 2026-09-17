import SwiftUI

struct PatientDetailView: View {
    let patient: Patient

    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations
    @State private var sessions: [SessionRecord] = []
    @State private var selectedSession: SessionRecord?
    @State private var notes: String = ""
    @State private var showPatientChat = false
    @State private var errorMessage: String?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 100, maxHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    .onChange(of: notes) { _, newValue in
                        // Skip the onAppear sync (notes = patient.notes)
                        // firing this too — only persist actual edits.
                        guard newValue != patient.notes else { return }
                        var updated = patient
                        updated.notes = newValue
                        appModel.savePatientNotes(updated)
                    }

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

                List(sessions, selection: $selectedSession) { session in
                    SessionRow(session: session).tag(session)
                }
                .listStyle(.inset)
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
            .frame(minWidth: 320)

            if let selectedSession {
                SessionDetailView(patient: patient, session: selectedSession, onSessionUpdated: refresh)
                    .id(selectedSession.id)
            } else {
                ContentUnavailableView(
                    "Select a Session",
                    systemImage: "waveform",
                    description: Text("Choose a session on the left, or start a new one.")
                )
            }
        }
        .navigationTitle(patient.name)
        .onAppear {
            notes = patient.notes
            refresh()
        }
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
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func refresh() {
        guard let store = appModel.store else { return }
        do {
            sessions = try store.listSessions(for: patient)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func newSession() {
        guard let store = appModel.store else { return }
        do {
            let session = try store.createSession(for: patient)
            refresh()
            selectedSession = session
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
        }
        .padding(.vertical, 2)
    }
}

private struct PatientChatSheet: View {
    let patient: Patient
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations
    @State private var messages: [ChatMessage] = []
    @State private var isSending = false
    @State private var errorMessage: String?
    @StateObject private var chatRunner = ChatStreamRunner()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Ask About \(patient.name)'s Sessions").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            ChatPaneView(title: "all sessions", messages: $messages, isSending: isSending, suggestions: SuggestedQuestions.patient, onSend: send, onStop: { chatRunner.stop() })
        }
        .onAppear {
            if let store = appModel.store {
                messages = store.loadPatientChat(for: patient)
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func send(_ question: String) {
        guard let store = appModel.store else { return }
        messages.append(ChatMessage(role: .user, text: question))
        isSending = true
        let assistantID = UUID()
        let context = store.gatherCitedPatientContext(for: patient, relevantTo: question)
        let stream = integrations.makeAssistantService()
            .streamAnswerAboutPatient(context: context.text, history: messages, question: question)
        chatRunner.start(
            stream: stream,
            // Stream the raw answer live; fold in the numbered source footer once
            // the full text is in, so citations don't flicker mid-stream.
            onReveal: { text in messages.upsert(id: assistantID, role: .assistant, text: text) },
            onError: { error in
                isSending = false
                errorMessage = error.localizedDescription
            },
            onFinish: { finalText in
                let decorated = Citations.decorate(answer: finalText, sources: context.sources)
                messages.upsert(id: assistantID, role: .assistant, text: decorated)
                isSending = false
                try? store.savePatientChat(messages, for: patient)
            }
        )
    }
}
