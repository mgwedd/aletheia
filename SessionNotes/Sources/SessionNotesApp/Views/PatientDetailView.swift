import SwiftUI

struct PatientDetailView: View {
    let patient: Patient

    @EnvironmentObject private var appModel: AppModel
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
                        var updated = patient
                        updated.notes = newValue
                        appModel.savePatientNotes(updated)
                    }

                Button {
                    showPatientChat = true
                } label: {
                    Label("Ask About All Sessions", systemImage: "bubble.left.and.bubble.right")
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
            }
            .padding()
            .frame(minWidth: 320)

            if let selectedSession {
                SessionDetailView(patient: patient, session: selectedSession)
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
    @EnvironmentObject private var settings: AppSettings
    @State private var messages: [ChatMessage] = []
    @State private var isSending = false
    @State private var errorMessage: String?
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
            ChatPaneView(title: "all sessions", messages: $messages, isSending: isSending, onSend: send)
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
        Task {
            defer { isSending = false }
            do {
                let context = try store.gatherPatientContext(for: patient)
                let prompt = Prompts.patientChat(context: context, history: messages, question: question)
                let client = OllamaClient(baseURL: settings.ollamaBaseURL)
                let response = try await client.generate(model: settings.ollamaModelName, prompt: prompt)
                messages.append(ChatMessage(role: .assistant, text: response))
                try? store.savePatientChat(messages, for: patient)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
