import Combine
import Foundation

/// One session's Ask tab: the conversation, the answer being written and the
/// rules around sending, stopping, compacting and saving.
@MainActor
final class SessionChatModel: ObservableObject {
    let runner = ChatStreamRunner()

    @Published var messages: [ChatMessage] = []
    @Published var isSending = false
    /// What part of the session the last answer read.
    @Published var coverage: String?

    var alert: (AIAlert) -> Void = { _ in }

    private var bag = Set<AnyCancellable>()
    private var appModel: AppModel!
    private var integrations: Integrations!
    private var settings: AppSettings!
    private(set) var patient: Patient!
    private(set) var session: SessionRecord!
    private(set) var material = SessionInputs()

    init() {
        runner.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
    }

    func configure(
        appModel: AppModel, integrations: Integrations, settings: AppSettings,
        patient: Patient, session: SessionRecord, material: SessionInputs
    ) {
        self.appModel = appModel
        self.integrations = integrations
        self.settings = settings
        self.patient = patient
        self.session = session
        self.material = material
    }

    /// Loads the saved conversation.
    func load() {
        guard let store = appModel.store else { return }
        messages = store.loadSessionChat(for: patient, session: session)
    }

    /// Caveats about the last answer, shown above the composer.
    var notices: [String] {
        var list: [String] = []
        if let coverage { list.append(coverage) }
        if runner.progress.stats?.possiblyTruncated == true && !isSending {
            list.append(AIRunStats.truncationNotice)
        }
        return list
    }

    func stop() { runner.stop() }

    func send(_ question: String) {
        guard let store = appModel.store else { return }
        let userMessage = ChatMessage(role: .user, text: question)
        // A question about My Notes is answered from them here, without the
        // model, which never reads them.
        if let reply = MyNotesLookup.answer(question: question, notes: material.myNotes) {
            messages.append(userMessage)
            messages.append(ChatMessage(role: .assistant, text: reply, fromMyNotes: true))
            coverage = nil
            let saved = messages
            appModel.attemptSave("chat") { try store.saveSessionChat(saved, for: self.patient, session: self.session) }
            return
        }
        // Past ChatMemory's budget, compact first so the answer still has the
        // whole conversation, the earlier part in summary.
        if ChatMemory.needsCompaction(messages) {
            compact("") { [weak self] in self?.send(question) }
            return
        }
        messages.append(userMessage)
        isSending = true
        let assistantID = UUID()
        // Snapshot the inputs now; the request itself is only made when the
        // queue starts this job (it may be waiting behind the note).
        let service = integrations.makeAssistantService(report: runner.reporter, clientName: patient.name)
        let transcript = material.transcriptText
        let notes = material.myNotes
        let sessionComments = material.comments
        let patientBackground = settings.includePatientBackground ? patient.aiBackgroundBlock : ""
        let history = messages
        let effort = settings.sessionChatEffort
        let model = service.model
        let patient = patient!
        let session = session!
        let runner = runner
        coverage = nil
        runner.start(
            queue: integrations.inferenceQueue,
            kind: .sessionChat,
            label: "session question",
            readTitle: "Reading the session",
            writeTitle: "Writing the answer",
            makeStream: { [self] in
                LongSessionChat.stream(
                    transcript: transcript,
                    notes: notes,
                    comments: sessionComments,
                    patientBackground: patientBackground,
                    history: history,
                    question: question,
                    effort: effort,
                    sessionID: session.id,
                    sessionDate: session.date,
                    folderName: session.folderName,
                    service: service,
                    builder: integrations.digests,
                    loadDigest: {
                        await Task.detached { store.digest(for: patient, session: session, model: model) }.value
                    },
                    saveDigest: { try store.saveDigest($0, for: patient, session: session) },
                    sectionCache: .store(store, patient: patient, session: session),
                    live: { started, change in runner.update(started: started, change) },
                    coverage: { [self] in coverage = $0 }
                )
            },
            onReveal: { [self] text in messages.upsert(id: assistantID, role: .assistant, text: text) },
            onError: { [self] error in
                isSending = false
                if let incident = AIEngineIncident.from(error: error) {
                    // The question stays in the conversation (nothing is lost if the
                    // alert is cancelled); a retry takes the unanswered turn out
                    // first so the question is asked once.
                    alert(.engine(incident, kind: .chat, retry: { [weak self] in
                        self?.messages.removeTurn(startingAt: userMessage.id)
                        self?.send(question)
                    }))
                } else {
                    alert(.message(error.localizedDescription))
                }
            },
            onFinish: { [self] _ in
                isSending = false
                appModel.attemptSave("chat") { try store.saveSessionChat(messages, for: patient, session: session) }
            },
            // Cancelled while waiting: the question never ran, so take it back
            // out of the conversation rather than leave it unanswered.
            onCancelledWhileQueued: { [self] in
                messages.removeAll { $0.id == userMessage.id }
                isSending = false
            }
        )
    }

    /// Replaces the conversation so far with the model's summary of it
    /// (`/compact`, the Compact button, or a send past the budget), then runs
    /// `next`. A stopped or failed summary is discarded: a partial one would
    /// stand in for messages it doesn't cover.
    func compact(_ focus: String, then next: (() -> Void)? = nil) {
        guard let store = appModel.store, !messages.isEmpty else { return }
        isSending = true
        let summaryID = UUID()
        let service = integrations.makeAssistantService(report: runner.reporter, clientName: patient.name)
        let history = messages
        let patient = patient!
        let session = session!
        runner.start(
            queue: integrations.inferenceQueue,
            kind: .sessionChat,
            label: "conversation summary",
            readTitle: "Reading the conversation",
            writeTitle: "Summarizing the conversation",
            makeStream: { service.streamCompaction(history: history, focus: focus) },
            onReveal: { [self] text in messages.upsert(id: summaryID, role: .summary, text: text) },
            onError: { [self] error in
                isSending = false
                messages.removeAll { $0.id == summaryID }
                alert(.message(error.localizedDescription))
            },
            onFinish: { [self] text in
                isSending = false
                guard !runner.wasStopped, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    messages.removeAll { $0.id == summaryID }
                    return
                }
                appModel.attemptSave("chat") { try store.saveSessionChat(messages, for: patient, session: session) }
                next?()
            },
            onCancelledWhileQueued: { [self] in isSending = false }
        )
    }
}
