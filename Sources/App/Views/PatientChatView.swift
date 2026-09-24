import SwiftUI

/// The patient's cross-session chat, as multiple browsable threads (ChatGPT
/// style) instead of one running log. A sidebar lists the threads (most recent
/// first, rename/delete in the context menu); the main pane is the shared
/// `ChatPaneView` bound to the selected thread. Each thread is a file under
/// `<patientDir>/ChatThreads/`, so they persist, back up, and encrypt like any
/// other PHI, and a legacy single-thread `patient_chat.json` is imported on
/// first open (see `Store.loadChatThreads`).
struct PatientChatView: View {
    let patient: Patient
    var onDone: () -> Void

    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations

    @State private var threads: [ChatThread] = []
    @State private var selectedThreadID: UUID?
    /// Working copy of the selected thread's messages, bound into `ChatPaneView`
    /// and written back to the thread file when a turn finishes.
    @State private var messages: [ChatMessage] = []
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var renamingThread: ChatThread?
    @State private var renameText = ""

    @StateObject private var chatRunner = ChatStreamRunner()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Ask About \(patient.name)'s Sessions").font(.headline)
                Spacer()
                Button("Done", action: onDone)
            }
            .padding()
            Divider()

            HSplitView {
                threadSidebar
                    .frame(minWidth: 200, idealWidth: 230, maxWidth: 320)

                if selectedThreadID != nil {
                    ChatPaneView(
                        title: "all sessions",
                        messages: $messages,
                        isSending: isSending,
                        suggestions: appModel.featureRegistry.contains(id: SuggestedQuestionsFeatureModule.id) ? SuggestedQuestions.patient : [],
                        onSend: send,
                        onStop: { chatRunner.stop() }
                    )
                    .frame(minWidth: 360)
                } else {
                    ContentUnavailableView {
                        Label("No Chat Selected", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Start a new chat to ask questions across \(patient.name)'s sessions.")
                    } actions: {
                        Button("New Chat") { startNewThread() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(minWidth: 360)
                }
            }
        }
        .onAppear { reloadThreads() }
        .onChange(of: selectedThreadID) { _, newID in
            // Load the newly-selected thread's messages, but never clobber an
            // in-flight working copy (persist() re-selects the same id).
            guard !isSending, let newID, let thread = threads.first(where: { $0.id == newID }) else { return }
            messages = thread.messages
        }
        .alert("Rename Chat", isPresented: renamingBinding) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renamingThread = nil }
            Button("Save") { commitRename() }
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var threadSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats").font(.subheadline.bold()).foregroundStyle(.secondary)
                Spacer()
                Button { startNewThread() } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("New chat")
                .disabled(isSending)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if threads.isEmpty {
                Spacer()
                Text("No chats yet.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(threads, selection: $selectedThreadID) { thread in
                    ThreadRow(thread: thread)
                        .contextMenu {
                            Button("Rename") { beginRename(thread) }
                            Button("Delete", role: .destructive) { deleteThread(thread) }
                        }
                }
                .listStyle(.sidebar)
                // Switching threads mid-generation would cross the streams.
                .disabled(isSending)
            }
        }
    }

    // MARK: - Bindings

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renamingThread != nil }, set: { if !$0 { renamingThread = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    // MARK: - Thread lifecycle

    private func reloadThreads(preserving id: UUID? = nil) {
        guard let store = appModel.store else { return }
        threads = store.loadChatThreads(for: patient)
        let target = id ?? selectedThreadID
        if let target, let thread = threads.first(where: { $0.id == target }) {
            selectedThreadID = thread.id
            if !isSending { messages = thread.messages }
        } else if let first = threads.first {
            selectedThreadID = first.id
            if !isSending { messages = first.messages }
        } else {
            selectedThreadID = nil
            if !isSending { messages = [] }
        }
    }

    private func startNewThread() {
        guard !isSending, let store = appModel.store else { return }
        let thread = ChatThread()
        try? store.saveChatThread(thread, for: patient)
        threads = store.loadChatThreads(for: patient)
        selectedThreadID = thread.id
        messages = []
    }

    private func beginRename(_ thread: ChatThread) {
        renamingThread = thread
        renameText = thread.title.isEmpty ? thread.displayTitle : thread.title
    }

    private func commitRename() {
        guard let store = appModel.store, var thread = renamingThread else { return }
        thread.title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        try? store.saveChatThread(thread, for: patient)
        renamingThread = nil
        reloadThreads(preserving: thread.id)
    }

    private func deleteThread(_ thread: ChatThread) {
        guard !isSending, let store = appModel.store else { return }
        try? store.deleteChatThread(id: thread.id, for: patient)
        if selectedThreadID == thread.id { selectedThreadID = nil }
        reloadThreads()
    }

    // MARK: - Sending

    private func send(_ question: String) {
        guard let store = appModel.store else { return }
        if selectedThreadID == nil { startNewThread() }
        guard let threadID = selectedThreadID else { return }

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
                persist(threadID: threadID)
            },
            onFinish: { finalText in
                // Source citations are a .preview-tier module; production shows
                // the raw answer without the numbered sources footer. See
                // SourceCitationsFeatureModule.
                let decorated = appModel.featureRegistry.contains(id: SourceCitationsFeatureModule.id)
                    ? Citations.decorate(answer: finalText, sources: context.sources)
                    : finalText
                messages.upsert(id: assistantID, role: .assistant, text: decorated)
                isSending = false
                persist(threadID: threadID)
            }
        )
    }

    /// Write the working `messages` back into the thread file, then reload so the
    /// sidebar re-sorts and picks up an auto-derived title.
    private func persist(threadID: UUID) {
        guard let store = appModel.store else { return }
        var thread = threads.first(where: { $0.id == threadID }) ?? ChatThread(id: threadID)
        thread.messages = messages
        thread.updatedAt = Date()
        try? store.saveChatThread(thread, for: patient)
        reloadThreads(preserving: threadID)
    }
}

private struct ThreadRow: View {
    let thread: ChatThread

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(thread.displayTitle)
                .lineLimit(1)
            Text(Self.relative.localizedString(for: thread.updatedAt, relativeTo: Date()))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
