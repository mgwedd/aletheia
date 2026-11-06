import Foundation

/// Writes a session's note in the background, with no screen open: the
/// "Write the summary after recording" setting. It runs the same note as the
/// Generate button (`SessionNoteModel`), so the result is saved as an unsigned
/// AI draft and "Summary ready" is posted through `PatientLabel`. When to run is
/// `DigestScheduler`'s call; this only starts, watches and stops one note.
@MainActor
final class AutoNoteDrafter {
    private let appModel: AppModel
    private let integrations: Integrations
    private let settings: AppSettings
    private var model: SessionNoteModel?

    init(appModel: AppModel, integrations: Integrations, settings: AppSettings) {
        self.appModel = appModel
        self.integrations = integrations
        self.settings = settings
    }

    /// The queue label of the note being written, while one is.
    private(set) var runningLabel: String?

    /// Whether a note started here is waiting, writing or winding down.
    var isRunning: Bool {
        guard let model, let runningLabel else { return false }
        return model.runner.isQueued || model.runner.isStreaming
            || integrations.inferenceQueue.hasJob(labelled: runningLabel)
    }

    static func label(for sessionID: UUID) -> String { "progress note \(sessionID.uuidString)" }

    /// Whether the session still wants a note: it has a transcript, nothing is
    /// saved for the chosen format and nothing in it is signed.
    func wants(patient: Patient, session: SessionRecord) -> Bool {
        guard let store = appModel.store else { return false }
        guard let transcript = try? store.readTranscript(for: patient, session: session),
              !transcript.isEmpty else { return false }
        if store.hasSignedNote(for: patient, session: session) { return false }
        let saved = store.note(for: patient, session: session, format: settings.progressNoteFormat) ?? ""
        return saved.isEmpty
    }

    /// Starts writing the session's note. False when it can't start now (a note
    /// for it is already being written, from its screen or here).
    func start(patient: Patient, session: SessionRecord) -> Bool {
        let label = Self.label(for: session.id)
        guard !integrations.inferenceQueue.hasJob(labelled: label), let store = appModel.store else { return false }
        let material = SessionInputs()
        material.transcriptText = (try? store.readTranscript(for: patient, session: session)) ?? ""
        material.myNotes = appModel.commentStore?.note(sessionID: session.id) ?? ""
        material.comments = appModel.commentStore?.comments(sessionID: session.id) ?? []
        let model = SessionNoteModel()
        model.configure(
            appModel: appModel, integrations: integrations, settings: settings,
            patient: patient, session: session, material: material)
        model.discardsStoppedNote = true
        model.sessionUpdated = { [weak appModel] in appModel?.refreshPatients() }
        model.refreshHasPreviousNote()
        model.generate()
        guard integrations.inferenceQueue.hasJob(labelled: label) else { return false }
        self.model = model
        runningLabel = label
        return true
    }

    /// Stops the note and keeps nothing of it (it is written again later).
    func stopAndDiscard() {
        model?.stop()
    }

    /// Forgets a note that has finished.
    func clear() {
        model = nil
        runningLabel = nil
    }
}
