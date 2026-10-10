import SwiftUI

/// The patient's cross-session chat, as multiple browsable threads (ChatGPT
/// style) instead of one running log. A sidebar lists the threads (most recent
/// first, rename/delete in the context menu); the main pane is the shared
/// `ChatPaneView` bound to the selected thread. Each thread is a `chatThread`
/// record in the SQLite store (`CommentStore`), so they persist, back up, and
/// encrypt like any other PHI, and a legacy single-thread `patient_chat.json`
/// is imported on first open (see `Store.loadChatThreads`).
///
/// This chat covers every session's generated notes and the therapist's own
/// notes and comments in full (per-session cap), but only a ranked ~6,000
/// characters of transcript per question (see docs/DESIGN-DECISIONS.md). Each
/// session's own chat lives inside that session.
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
    /// Set when a request failed because the local AI engine is down or missing
    /// its model; the alert offers a one-click fix and then re-asks `retryQuestion`.
    @State private var engineProblem: AIEngineProblem?
    @State private var retryQuestion: String?
    @State private var renamingThread: ChatThread?
    @State private var renameText = ""
    /// Sessions whose transcript couldn't be read when the last question was
    /// asked; non-zero shows a caption that answers may be incomplete.
    @State private var unreadableSessions = 0
    /// How much transcript text the last question's context held; nil until a
    /// question is asked or when everything fit.
    @State private var coverageNotice: String?

    @StateObject private var chatRunner = ChatStreamRunner()

    //   header      title · Done
    //   sidebar     CHATS eyebrow · new chat · thread rows
    //   pane        the shared ChatPaneView, or an empty state with New Chat
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Ask About All of \(patient.name)'s Sessions")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.text.color)
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.themed)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Theme.window.color)
            .themeDivider(.bottom)

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
                        onStop: { chatRunner.stop() },
                        queuedStatus: chatRunner.queuedStatus,
                        scopeNote: scopeNote,
                        notices: notices
                    )
                    .frame(minWidth: 360)
                } else {
                    noChatSelected
                        .frame(minWidth: 360)
                }
            }
        }
        .background(Theme.window.color)
        .onAppear { reloadThreads() }
        .onChange(of: selectedThreadID) { _, newID in
            // The notice belongs to the question just asked, not to other threads.
            if !isSending {
                unreadableSessions = 0
                coverageNotice = nil
            }
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
        .aiEngineProblemAlert($engineProblem) {
            if let question = retryQuestion {
                retryQuestion = nil
                send(question)
            }
        }
    }

    /// What the answers draw on, matching what `gatherCitedPatientContext`
    /// sends: every session's generated notes, notes and comments, and a ranked
    /// slice of transcript within the character budget.
    private var scopeNote: String {
        "Answers come from every session's generated notes, your notes and comments, plus about \(PatientContextRetriever.defaultCharacterBudget.formatted()) characters of transcript chosen for each question. To ask about one session in full, open it and use its Ask tab."
    }

    /// Caveats about the last question's context, shown above the composer.
    private var notices: [String] {
        var lines: [String] = []
        if let coverageNotice { lines.append(coverageNotice) }
        if unreadableSessions > 0 {
            lines.append("\(unreadableSessions) session(s) could not be read; answers may be incomplete.")
        }
        return lines
    }

    private var noChatSelected: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.muted.color)
                .accessibilityHidden(true)
            Text("No Chat Selected")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.text.color)
            Text("Start a new chat to ask questions across all of \(patient.name)'s sessions: transcripts, notes and comments. Chats about a single session live inside that session.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.muted.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("New Chat") { startNewThread() }
                .buttonStyle(.themePrimary)
                .padding(.top, 8)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel.color)
    }

    private var threadSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats").eyebrowStyle()
                Spacer()
                Button { startNewThread() } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .buttonStyle(.themeIcon)
                .help("New chat")
                .disabled(isSending)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .themeDivider(.bottom)

            if threads.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Theme.muted.color)
                        .accessibilityHidden(true)
                    Text("No chats yet")
                        .font(Theme.Typography.control)
                        .foregroundStyle(Theme.text.color)
                    Text("Chats here cover all of \(patient.name)'s sessions. Per-session chats live inside each session.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                        .multilineTextAlignment(.center)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(threads) { thread in
                            ThreadRow(thread: thread, isSelected: thread.id == selectedThreadID) {
                                selectedThreadID = thread.id
                            }
                            .contextMenu {
                                Button("Rename") { beginRename(thread) }
                                Button("Delete", role: .destructive) { deleteThread(thread) }
                            }
                        }
                    }
                    .padding(8)
                }
                // Up / Down move the selection, as in a native list.
                .focusable()
                .focusEffectDisabled()
                .onMoveCommand { direction in moveSelection(direction) }
                // Switching threads mid-generation would cross the streams.
                .disabled(isSending)
            }
        }
        .background(Theme.sidebar.color)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !threads.isEmpty else { return }
        let current = threads.firstIndex(where: { $0.id == selectedThreadID })
        switch direction {
        case .up:
            selectedThreadID = threads[max((current ?? 1) - 1, 0)].id
        case .down:
            selectedThreadID = threads[min((current ?? -1) + 1, threads.count - 1)].id
        default:
            break
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
        appModel.attemptSave("chat") { try store.saveChatThread(thread, for: patient) }
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
        appModel.attemptSave("chat") { try store.saveChatThread(thread, for: patient) }
        renamingThread = nil
        reloadThreads(preserving: thread.id)
    }

    private func deleteThread(_ thread: ChatThread) {
        guard !isSending, let store = appModel.store else { return }
        appModel.attemptSave("chat") { try store.deleteChatThread(id: thread.id, for: patient) }
        if selectedThreadID == thread.id { selectedThreadID = nil }
        reloadThreads()
    }

    // MARK: - Sending

    private func send(_ question: String) {
        guard let store = appModel.store else { return }
        if selectedThreadID == nil { startNewThread() }
        guard let threadID = selectedThreadID else { return }

        // The prompt carries the question on its own line, so the history
        // snapshot is taken before the question is appended to it.
        let history = messages
        let userMessage = ChatMessage(role: .user, text: question)
        messages.append(userMessage)
        isSending = true
        let assistantID = UUID()
        let context = store.gatherCitedPatientContext(for: patient, relevantTo: question)
        unreadableSessions = context.unreadableSessions
        coverageNotice = context.coverage.notice
        // Snapshot everything the prompt needs now; the request itself is only
        // made when the queue starts this job.
        let service = integrations.makeAssistantService()
        chatRunner.start(
            queue: integrations.inferenceQueue,
            kind: .patientChat,
            label: "patient question",
            makeStream: {
                service.streamAnswerAboutPatient(context: context.text, history: history, question: question)
            },
            // Stream the raw answer live; fold in the numbered source footer once
            // the full text is in, so citations don't flicker mid-stream.
            onReveal: { text in messages.upsert(id: assistantID, role: .assistant, text: text) },
            onError: { error in
                isSending = false
                if let problem = AIEngineProblem.from(error: error, ollamaInstalled: OllamaAppLocator.isInstalled()) {
                    // Take the unanswered question back out so a retry asks it once.
                    if let index = messages.firstIndex(where: { $0.id == userMessage.id }) {
                        messages.removeSubrange(index...)
                    }
                    retryQuestion = question
                    engineProblem = problem
                } else {
                    errorMessage = error.localizedDescription
                }
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
            },
            // Cancelled while waiting: the question never ran, so take it back
            // out of the thread rather than leave it unanswered.
            onCancelledWhileQueued: {
                messages.removeAll { $0.id == userMessage.id }
                isSending = false
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
        // On a failed save, keep the conversation on screen (reloading from the
        // database would replace it with the older stored copy) so the therapist
        // can still read or copy it while the "couldn't save" notice is showing.
        if appModel.attemptSave("chat", { try store.saveChatThread(thread, for: patient) }) {
            reloadThreads(preserving: threadID)
        }
    }
}

/// One thread in the sidebar: title and relative time, the accent tint when
/// selected, the hover fill under the pointer.
private struct ThreadRow: View {
    let thread: ChatThread
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var fill: Color {
        if isSelected { return Theme.accentTint.color }
        return isHovered ? Theme.hover.color : .clear
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.displayTitle)
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(1)
                Text(Self.relative.localizedString(for: thread.updatedAt, relativeTo: Date()))
                    .font(Theme.Typography.caption)
                    // Muted ink has no contrast pairing on the selected tint.
                    .foregroundStyle(isSelected ? Theme.text.color : Theme.muted.color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(fill, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
