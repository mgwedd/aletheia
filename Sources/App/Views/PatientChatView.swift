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
/// notes and comments (per-session cap), plus the transcript passages that a
/// search of every session finds for the question (see `SessionSearch`), up to
/// a character budget. Each session's own chat lives inside that session.
struct PatientChatView: View {
    let patient: Patient
    var onDone: () -> Void

    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations
    @EnvironmentObject private var settings: AppSettings

    @State private var threads: [ChatThread] = []
    @State private var selectedThreadID: UUID?
    /// Working copy of the selected thread's messages, bound into `ChatPaneView`
    /// and written back to the thread file when a turn finishes.
    @State private var messages: [ChatMessage] = []
    @State private var isSending = false
    @State private var errorMessage: String?
    /// Set when a request failed because the local AI engine is down or missing
    /// its model; the alert offers a one-click fix and then re-asks the pending question.
    @State private var engineIncident: AIEngineIncident?
    @State private var pendingRetries = PendingRetries<String, () -> Void>()
    @State private var renamingThread: ChatThread?
    @State private var renameText = ""
    /// Sessions whose transcript couldn't be read when the last question was
    /// asked; non-zero shows a caption that answers may be incomplete.
    /// How much transcript text the last question's context held; nil until a
    /// question is asked or when everything fit.
    @State private var coverageNotice: String?
    /// Shown while the sessions are being decrypted and searched, before the model starts.
    @State private var searchingNotice: String?

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

            AIEngineBanner()

            SummaryStatusRow(scheduler: integrations.digestScheduler, patientID: patient.id)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)

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
                        notices: notices,
                        busyNotice: searchingNotice,
                        onCompact: { compact($0) },
                        progress: chatRunner.progress,
                        speed: integrations.modelSpeed,
                        effort: $settings.patientChatEffort
                    )
                    .frame(minWidth: 360)
                } else {
                    noChatSelected
                        .frame(minWidth: 360)
                }
            }
        }
        .background(Theme.window.color)
        .onAppear {
            reloadThreads()
            integrations.digestScheduler.patientOpened(patient)
        }
        .onChange(of: selectedThreadID) { _, newID in
            // The notice belongs to the question just asked, not to other threads.
            if !isSending {
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
        .aiEngineAlert($engineIncident, retry: {
            for retry in pendingRetries.takeAll() { retry() }
        }, discard: {
            pendingRetries.clear()
        })
    }

    /// What the answers draw on, matching what `gatherCitedPatientContext`
    /// sends: every session's generated notes, notes and comments, and the
    /// transcript passages a search of all sessions finds for the question.
    private var scopeNote: String {
        "Answers come from every session's generated notes, your notes and comments, plus the transcript passages found by searching all sessions for the names and words in your question. Each answer shows what it read. To ask about one session in full, open it and use its Ask tab."
    }

    /// Caveats about the last question's context, shown above the composer.
    private var notices: [String] {
        var lines: [String] = []
        if let coverageNotice { lines.append(coverageNotice) }
        if chatRunner.progress.stats?.possiblyTruncated == true && !isSending {
            lines.append(AIRunStats.truncationNotice)
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
        // Past ChatMemory's budget, compact first so the answer still has the
        // whole conversation, the earlier part in summary.
        if ChatMemory.needsCompaction(messages) {
            compact("") { send(question) }
            return
        }

        // The prompt carries the question on its own line, so the history
        // snapshot is taken before the question is appended to it.
        let history = messages
        let userMessage = ChatMessage(role: .user, text: question)
        messages.append(userMessage)
        isSending = true
        let assistantID = UUID()
        // Snapshot everything the prompt needs now; the request itself is only
        // made when the queue starts this job.
        let service = integrations.makeAssistantService(report: chatRunner.reporter)
        // The whole context is sized from this Mac's budget less the
        // instructions, the conversation and the question.
        let characterBudget = service.patientContextCharacters(history: history, question: question)
        guard characterBudget >= Self.minimumContextCharacters else {
            messages.removeAll { $0.id == userMessage.id }
            isSending = false
            errorMessage = PatientContextBudgetError().localizedDescription
            return
        }
        let effort = settings.patientChatEffort
        let initialBudget = PatientChatAnswer.initialContextBudget(for: effort, totalBudget: characterBudget)
        // Decrypting and searching every session takes a moment on a long
        // history, so it runs off the main thread with a line saying so.
        let sessionCount = (try? store.listSessions(for: patient))?.count ?? 0
        searchingNotice = Self.searchingNotice(sessions: sessionCount)
        let patient = patient
        let includeBackground = settings.includePatientBackground
        Task {
            let context = await Task.detached(priority: .userInitiated) {
                store.gatherCitedPatientContext(
                    for: patient,
                    relevantTo: question,
                    characterBudget: initialBudget,
                    includeBackground: includeBackground
                )
            }.value
            searchingNotice = nil
            startAnswer(
                service: service, context: context, history: history, question: question,
                effort: effort, totalBudget: characterBudget,
                userMessage: userMessage, assistantID: assistantID, threadID: threadID
            )
        }
    }

    /// The line shown while the history is searched; no count when none is known.
    static func searchingNotice(sessions n: Int) -> String {
        n > 0 ? "Searching \(n) session\(n == 1 ? "" : "s")…" : "Searching…"
    }

    /// Room (characters) below which a patient question can't be answered
    /// usefully: the instructions and conversation have used the budget.
    private static let minimumContextCharacters = 2_000

    private func startAnswer(
        service: AssistantService, context: PatientContext, history: [ChatMessage], question: String,
        effort: AnswerEffort, totalBudget: Int,
        userMessage: ChatMessage, assistantID: UUID, threadID: UUID
    ) {
        guard let store = appModel.store else { return }
        let patient = patient
        var initialCoverage = context.coverage
        initialCoverage.effort = effort
        var latestCoverageLabel = initialCoverage.label
        // Grows when a follow-up lookup reads a session the context didn't hold,
        // so a citation of that session shows its date and is listed.
        var answerSources = context.sources
        // What the notice and caption say comes from what was sent: they are
        // set once the answer starts (or ends), never for a run that was refused.
        func showCoverage() {
            coverageNotice = latestCoverageLabel
        }
        coverageNotice = nil
        chatRunner.start(
            queue: integrations.inferenceQueue,
            kind: .patientChat,
            label: "patient question",
            readTitle: "Reading the sessions",
            writeTitle: "Writing the answer",
            makeStream: {
                PatientChatAnswer.stream(
                    context: context,
                    history: history,
                    question: question,
                    effort: effort,
                    totalBudget: totalBudget,
                    scope: {
                        await Task.detached(priority: .userInitiated) {
                            store.localToolScope(for: patient)
                        }.value
                    },
                    service: service,
                    builder: integrations.digests,
                    live: { started, change in chatRunner.update(started: started, change) },
                    onCoverage: { updated in
                        latestCoverageLabel = updated.label
                        if isSending { coverageNotice = updated.label }
                    },
                    onSources: { answerSources = $0 }
                )
            },
            // Stream the raw answer live; fold in the numbered source footer once
            // the full text is in, so citations don't flicker mid-stream.
            onReveal: { text in
                showCoverage()
                messages.upsert(id: assistantID, role: .assistant, text: text)
            },
            onError: { error in
                isSending = false
                if let incident = AIEngineIncident.from(error: error, ollamaInstalled: OllamaAppLocator.isInstalled()) {
                    // The question stays in the thread (and nothing is lost if the
                    // alert is cancelled); a retry takes the unanswered turn out
                    // first so the question is asked once.
                    pendingRetries.set({
                        messages.removeTurn(startingAt: userMessage.id)
                        send(question)
                    }, for: "chat")
                    engineIncident = incident
                } else if error is ContextBudgetError {
                    // Refused before anything was sent: no coverage to show.
                    errorMessage = PatientContextBudgetError().localizedDescription
                } else {
                    errorMessage = error.localizedDescription
                }
                persist(threadID: threadID)
            },
            onFinish: { finalText in
                showCoverage()
                // Builds without the SourceCitationsFeatureModule show the raw
                // answer, without the sources footer.
                let decorated = Citations.display(
                    answer: finalText,
                    sources: answerSources,
                    enabled: appModel.featureRegistry.contains(id: SourceCitationsFeatureModule.id)
                )
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

    /// Replaces the thread so far with the model's summary of it (`/compact`,
    /// the Compact button, or a send past the budget), then runs `next`. A
    /// stopped or failed summary is discarded: a partial one would stand in
    /// for messages it doesn't cover.
    private func compact(_ focus: String, then next: (() -> Void)? = nil) {
        guard let threadID = selectedThreadID, !messages.isEmpty else { return }
        isSending = true
        let summaryID = UUID()
        let service = integrations.makeAssistantService(report: chatRunner.reporter)
        let history = messages
        chatRunner.start(
            queue: integrations.inferenceQueue,
            kind: .patientChat,
            label: "conversation summary",
            readTitle: "Reading the conversation",
            writeTitle: "Summarizing the conversation",
            makeStream: { service.streamCompaction(history: history, focus: focus) },
            onReveal: { text in messages.upsert(id: summaryID, role: .summary, text: text) },
            onError: { error in
                isSending = false
                messages.removeAll { $0.id == summaryID }
                errorMessage = error.localizedDescription
            },
            onFinish: { text in
                isSending = false
                guard !chatRunner.wasStopped, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    messages.removeAll { $0.id == summaryID }
                    return
                }
                persist(threadID: threadID)
                next?()
            },
            onCancelledWhileQueued: { isSending = false }
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
