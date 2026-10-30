import Combine
import Foundation

/// A patient's cross-session chat: the list of threads, the open conversation,
/// and the rules around asking, stopping, compacting, renaming and deleting.
/// Each thread is stored with the patient's other records.
@MainActor
final class PatientChatModel: ObservableObject {
    let runner = ChatStreamRunner()

    @Published private(set) var threads: [ChatThread] = []
    @Published private(set) var selectedThreadID: UUID?
    /// Working copy of the selected thread's messages, written back when a turn finishes.
    @Published var messages: [ChatMessage] = []
    /// A question held for a compaction that failed or was stopped; the
    /// composer takes it back so nothing typed is lost.
    @Published var returnedQuestion: String?
    @Published private(set) var isSending = false
    /// Shown while the sessions are being decrypted and searched, before the model starts.
    @Published private(set) var searchingNotice: String?
    /// When the current Ask began searching: the status line counts from here.
    @Published private(set) var searchingSince: Date?
    /// What the last answer read ("Read: ..."), shown under it.
    @Published private(set) var coverage: String?

    var alert: (AIAlert) -> Void = { _ in }

    private var searchTask: Task<Void, Never>?
    private var searchingMessageID: UUID?
    private var bag = Set<AnyCancellable>()
    private var appModel: AppModel!
    private var integrations: Integrations!
    private var settings: AppSettings!
    private(set) var patient: Patient!

    /// Room (characters) below which a patient question can't be answered
    /// usefully: the instructions and conversation have used the budget.
    private static let minimumContextCharacters = 2_000

    init() {
        runner.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
    }

    func configure(appModel: AppModel, integrations: Integrations, settings: AppSettings, patient: Patient) {
        self.appModel = appModel
        self.integrations = integrations
        self.settings = settings
        self.patient = patient
    }

    /// Caveats about the last answer, shown above the composer.
    var notices: [String] {
        var lines: [String] = []
        if let coverage { lines.append(coverage) }
        if runner.progress.stats?.possiblyTruncated == true && !isSending {
            lines.append(AIRunStats.truncationNotice)
        }
        return lines
    }

    // MARK: - Thread lifecycle

    func reloadThreads(preserving id: UUID? = nil) {
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

    /// Opens a thread. Never clobbers an in-flight working copy.
    func select(_ id: UUID?) {
        selectedThreadID = id
        guard !isSending, let id, let thread = threads.first(where: { $0.id == id }) else { return }
        messages = thread.messages
    }

    func startNewThread() {
        guard !isSending, let store = appModel.store else { return }
        let thread = ChatThread()
        appModel.attemptSave("chat") { try store.saveChatThread(thread, for: patient) }
        threads = store.loadChatThreads(for: patient)
        selectedThreadID = thread.id
        messages = []
    }

    func rename(_ thread: ChatThread, to title: String) {
        guard let store = appModel.store else { return }
        var thread = thread
        thread.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        appModel.attemptSave("chat") { try store.saveChatThread(thread, for: patient) }
        reloadThreads(preserving: thread.id)
    }

    func delete(_ thread: ChatThread) {
        guard !isSending, let store = appModel.store else { return }
        appModel.attemptSave("chat") { try store.deleteChatThread(id: thread.id, for: patient) }
        if selectedThreadID == thread.id { selectedThreadID = nil }
        reloadThreads()
    }

    // MARK: - Sending

    func send(_ question: String) {
        guard let store = appModel.store else { return }
        if selectedThreadID == nil { startNewThread() }
        guard let threadID = selectedThreadID else { return }
        // Past ChatMemory's budget, compact first so the answer still has the
        // whole conversation, the earlier part in summary.
        if ChatMemory.needsCompaction(messages, window: integrations.makeAssistantService().budget) {
            compact("", then: { [weak self] in self?.send(question) }, otherwise: { [weak self] in self?.returnedQuestion = question })
            return
        }

        // The prompt carries the question on its own line, so the history
        // snapshot is taken before the question is appended to it.
        let history = messages
        let userMessage = ChatMessage(role: .user, text: question)
        messages.append(userMessage)
        isSending = true
        coverage = nil
        let assistantID = UUID()
        // Snapshot everything the prompt needs now; the request itself is only
        // made when the queue starts this job.
        let service = integrations.makeAssistantService(report: runner.reporter, clientName: patient.name)
        // The whole context is sized from this Mac's budget less the
        // instructions, the conversation and the question.
        let characterBudget = service.patientContextCharacters(history: history, question: question)
        guard characterBudget >= Self.minimumContextCharacters else {
            messages.removeAll { $0.id == userMessage.id }
            isSending = false
            alert(.message(PatientContextBudgetError().localizedDescription))
            return
        }
        let effort = settings.patientChatEffort
        let initialBudget = PatientChatAnswer.initialContextBudget(for: effort, totalBudget: characterBudget)
        // Decrypting and searching every session takes a moment on a long
        // history, so it runs off the main thread with a line saying so.
        let sessionCount = (try? store.listSessions(for: patient))?.count ?? 0
        searchingNotice = PatientAskSteps.gatheringText(
            sessions: sessionCount, terms: SessionSearch.terms(from: question).map(\.text))
        let askedAt = Date()
        searchingSince = askedAt
        let patient = patient!
        let includeBackground = settings.includePatientBackground
        searchingMessageID = userMessage.id
        searchTask = Task {
            let context = await Task.detached(priority: .userInitiated) {
                store.gatherCitedPatientContext(
                    for: patient,
                    relevantTo: question,
                    characterBudget: initialBudget,
                    includeBackground: includeBackground
                )
            }.value
            // Stopped while gathering: `stop` has already put things back.
            guard !Task.isCancelled else { return }
            searchTask = nil
            searchingMessageID = nil
            searchingNotice = nil
            searchingSince = nil
            startAnswer(
                service: service, context: context, history: history, question: question,
                effort: effort, totalBudget: characterBudget, askedAt: askedAt,
                userMessage: userMessage, assistantID: assistantID, threadID: threadID
            )
        }
    }

    /// Stop: the running answer, or, while the sessions are still being gathered
    /// (the model hasn't started), that lookup, taking the unanswered question
    /// back out of the thread.
    func stop() {
        if let searchTask {
            searchTask.cancel()
            self.searchTask = nil
            if let id = searchingMessageID { messages.removeAll { $0.id == id } }
            searchingMessageID = nil
            searchingNotice = nil
            searchingSince = nil
            isSending = false
        } else {
            runner.stop()
        }
    }

    private func startAnswer(
        service: AssistantService, context: PatientContext, history: [ChatMessage], question: String,
        effort: AnswerEffort, totalBudget: Int, askedAt: Date,
        userMessage: ChatMessage, assistantID: UUID, threadID: UUID
    ) {
        guard let store = appModel.store else { return }
        let patient = patient!
        let runner = runner
        // Grows when a follow-up lookup reads a session the context didn't hold,
        // so a citation of that session shows its date and is listed.
        var answerSources = context.sources
        runner.start(
            queue: integrations.inferenceQueue,
            kind: .patientChat,
            label: "patient question",
            readTitle: "Reading what was gathered",
            writeTitle: "Writing the answer",
            runStartedAt: askedAt,
            makeStream: { [self] in
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
                    live: { started, change in runner.update(started: started, change) },
                    onCoverage: { [self] in coverage = $0.label },
                    onSources: { answerSources = $0 }
                )
            },
            // Stream the raw answer live; fold in the numbered source footer once
            // the full text is in, so citations don't flicker mid-stream.
            onReveal: { [self] text in
                messages.upsert(id: assistantID, role: .assistant, text: text)
            },
            onError: { [self] error in
                isSending = false
                if let incident = AIEngineIncident.from(error: error) {
                    // The question stays in the thread (and nothing is lost if the
                    // alert is cancelled); a retry takes the unanswered turn out
                    // first so the question is asked once.
                    alert(.engine(incident, kind: .chat, retry: { [weak self] in
                        self?.messages.removeTurn(startingAt: userMessage.id)
                        self?.send(question)
                    }))
                } else if error is ContextBudgetError {
                    // Refused before anything was sent: no coverage to show.
                    alert(.message(PatientContextBudgetError().localizedDescription))
                } else {
                    alert(.message(error.localizedDescription))
                }
                persist(threadID: threadID)
            },
            onFinish: { [self] finalText in
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
            onCancelledWhileQueued: { [self] in
                messages.removeAll { $0.id == userMessage.id }
                isSending = false
            }
        )
    }

    /// Replaces the thread so far with the model's summary of it (`/compact`,
    /// the Compact button, or a send past the budget), then runs `next`. A
    /// stopped or failed summary is discarded: a partial one would stand in
    /// for messages it doesn't cover.
    func compact(_ focus: String, then next: (() -> Void)? = nil, otherwise abandoned: (() -> Void)? = nil) {
        guard let threadID = selectedThreadID, !messages.isEmpty else { return }
        isSending = true
        let summaryID = UUID()
        let service = integrations.makeAssistantService(report: runner.reporter, clientName: patient.name)
        let history = messages
        runner.start(
            queue: integrations.inferenceQueue,
            kind: .patientChat,
            label: "conversation summary",
            readTitle: "Reading the conversation",
            writeTitle: "Summarizing the conversation",
            makeStream: { service.streamCompaction(history: history, focus: focus) },
            onReveal: { [self] text in messages.upsert(id: summaryID, role: .summary, text: text) },
            onError: { [self] error in
                isSending = false
                messages.removeAll { $0.id == summaryID }
                abandoned?()
                alert(.message(error.localizedDescription))
            },
            onFinish: { [self] text in
                guard !runner.wasStopped, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    isSending = false
                    messages.removeAll { $0.id == summaryID }
                    abandoned?()
                    return
                }
                persist(threadID: threadID)
                if let next {
                    DispatchQueue.main.async { next() }
                } else {
                    isSending = false
                }
            },
            onCancelledWhileQueued: { [self] in
                isSending = false
                abandoned?()
            }
        )
    }

    /// Write the working `messages` back into the thread, then reload so the
    /// list re-sorts and picks up an auto-derived title.
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
