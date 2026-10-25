import AppKit
import Combine
import Foundation

/// One session's progress-note pane: the saved note for the chosen format, the
/// generation that writes it, and the edit, restore and regenerate rules around
/// it. The session screen shows this state; it holds no note logic of its own.
@MainActor
final class SessionNoteModel: ObservableObject {
    let runner = ChatStreamRunner()
    /// The Copy button's "Copied" feedback.
    let copyFeedback = CopyFeedback()

    /// The note shown for the chosen format.
    @Published var summaryText = ""
    /// Fingerprint of the transcript the shown note was written from.
    @Published var noteFingerprint: String?
    @Published var noteCoverage: String?
    @Published var generatingFormat: ProgressNoteFormat = .default
    @Published var noteHighWater = ProgressHighWater()
    @Published var isEditingNote = false
    @Published var noteDraft = ""
    @Published var confirmRegenerate = false
    @Published var hasPreviousNote = false
    /// Where the displayed format's note stands: draft, signed or altered.
    @Published var noteStatus: NoteLifecycle.Status = .draft
    /// Whether the displayed note started as AI output.
    @Published var noteIsAI = false
    /// Whether any format's note in this session is signed (the transcript is then read-only).
    @Published var sessionHasSigned = false
    @Published var confirmingSign = false
    @Published var confirmingReopen = false
    /// Why a note was not exported or copied; shown until dismissed.
    @Published var reviewBlock: String?

    /// Set when the person pressed Stop or Cancel; read when the run ends.
    var noteStopping = false

    /// Where alerts go (the screen shows them).
    var alert: (AIAlert) -> Void = { _ in }
    /// Called after the note on disk changed, so lists can refresh.
    var sessionUpdated: () -> Void = {}

    private var noteWaiter: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    private var appModel: AppModel!
    private var integrations: Integrations!
    private var settings: AppSettings!
    private(set) var patient: Patient!
    private(set) var session: SessionRecord!
    private(set) var material = SessionInputs()

    init() {
        runner.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        copyFeedback.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
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

    var isConfigured: Bool { appModel != nil }

    // MARK: - Showing the saved note

    /// Shows what is saved for `format`.
    func showSaved(for format: ProgressNoteFormat) {
        isEditingNote = false
        summaryText = savedNote(for: format)
        noteFingerprint = savedFingerprint(for: format)
        noteCoverage = savedCoverage(for: format)
        refreshHasPreviousNote()
    }

    func savedNote(for format: ProgressNoteFormat) -> String {
        appModel.store?.note(for: patient, session: session, format: format) ?? ""
    }

    func savedFingerprint(for format: ProgressNoteFormat) -> String? {
        appModel.store?.noteTranscriptFingerprint(for: patient, session: session, format: format)
    }

    func savedCoverage(for format: ProgressNoteFormat) -> String? {
        appModel.store?.noteCoverage(for: patient, session: session, format: format)
    }

    func refreshHasPreviousNote() {
        guard let store = appModel.store else { hasPreviousNote = false; return }
        hasPreviousNote = store.previousNote(for: patient, session: session, format: settings.progressNoteFormat) != nil
        refreshNoteStatus()
    }

    // MARK: - Signing

    /// A signed (or altered-after-signing) note is read-only until reopened.
    var noteLocked: Bool { !noteStatus.isDraft }

    func refreshNoteStatus() {
        guard let store = appModel.store else { return }
        let format = settings.progressNoteFormat
        sessionHasSigned = store.hasSignedNote(for: patient, session: session)
        do {
            noteStatus = try store.noteLifecycle(for: patient, session: session, format: format)
        } catch {
            // A signature that can't be read keeps the note locked.
            noteStatus = .altered(SignedNote(signedAt: .distantPast, signer: "unknown", sha256: "", aiGenerated: true))
        }
        noteIsAI = NoteLifecycle.isAIGenerated(store.noteEditState(for: patient, session: session, format: format))
    }

    /// Whether the displayed note may be exported or copied; if not, says why.
    func mayLeave(message: String) -> Bool {
        if NoteLifecycle.allowsLeaving(noteStatus, aiGenerated: noteIsAI) { return true }
        reviewBlock = message
        return false
    }

    func sign() {
        guard let store = appModel.store else { return }
        do {
            try store.signNote(for: patient, session: session, format: settings.progressNoteFormat)
            refreshNoteStatus()
            sessionUpdated()
        } catch {
            alert(.message(error.localizedDescription))
        }
    }

    func reopen() {
        guard let store = appModel.store else { return }
        do {
            try store.reopenSignedNote(for: patient, session: session, format: settings.progressNoteFormat)
            refreshNoteStatus()
            refreshHasPreviousNote()
            sessionUpdated()
        } catch {
            alert(.message(error.localizedDescription))
        }
    }

    /// The shown note was generated from an earlier version of the saved
    /// transcript. Hidden while a (re)generation is running.
    var noteIsOutdated: Bool {
        !summaryText.isEmpty && !runner.isStreaming && !runner.isQueued
            && NoteFreshness.isOutdated(recorded: noteFingerprint, transcript: material.transcriptText)
    }

    /// Copy: the shown note with its formatting, to paste into an EHR or a document.
    func copyNote(to pasteboard: NSPasteboard = PHIPasteboard.general) {
        guard mayLeave(message: NoteLifecycle.reviewToCopy) else { return }
        RichClipboard.write(RichClipboard.payload(markdown: summaryText), to: pasteboard)
        copyFeedback.flash()
    }

    // MARK: - Editing

    func beginEditing() {
        noteDraft = summaryText
        isEditingNote = true
    }

    func cancelEditing() { isEditingNote = false }

    var canSaveEdit: Bool { NoteEditing.canSave(draft: noteDraft, original: summaryText) }

    func saveEdited() {
        guard let store = appModel.store else { return }
        guard canSaveEdit else { return }
        do {
            try store.saveEditedNote(noteDraft, for: patient, session: session, format: settings.progressNoteFormat)
            summaryText = noteDraft
            isEditingNote = false
            sessionUpdated()
        } catch {
            alert(.message(error.localizedDescription))
        }
    }

    func restorePrevious() {
        guard let store = appModel.store else { return }
        do {
            if let restored = try store.restorePreviousNote(for: patient, session: session, format: settings.progressNoteFormat) {
                summaryText = restored
                sessionUpdated()
            }
        } catch {
            alert(.message(error.localizedDescription))
        }
    }

    // MARK: - Generating

    /// Regenerate asks first when it would replace the user's edits; an
    /// untouched generated note is replaced straight away. (The Store keeps the
    /// edited text as the previous version either way.)
    func requestGenerate() {
        guard let store = appModel.store, !noteLocked else { return }
        let state = store.noteEditState(for: patient, session: session, format: settings.progressNoteFormat)
        if state == .unreadable {
            alert(.message(StoreError.noteUnreadable.localizedDescription))
        } else if NoteEditing.shouldArchiveBeforeReplacing(state) {
            confirmRegenerate = true
        } else {
            generate()
        }
    }

    /// Stop while writing; Cancel while waiting.
    func stop() {
        noteStopping = true
        runner.stop()
    }

    /// A note must not start after the person has left.
    func cancelWaiter() {
        noteWaiter?.cancel()
        noteWaiter = nil
    }

    func generate() {
        guard let store = appModel.store else { return }
        // One note per session at a time, even across leaving and reopening the session.
        let jobLabel = "progress note \(session.id.uuidString)"
        guard !integrations.inferenceQueue.hasJob(labelled: jobLabel) else {
            if noteStopping {
                // Just stopped: start again once the old job has unwound, with no alert.
                // Only the first waiter goes on; a second click finds the flag already cleared.
                guard noteWaiter == nil else { return }
                noteWaiter = Task { @MainActor in
                    let deadline = Date().addingTimeInterval(10)
                    while integrations.inferenceQueue.hasJob(labelled: jobLabel), !Task.isCancelled, Date() < deadline {
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                    // A cancelled waiter may already have been replaced; leave the new one alone.
                    if !Task.isCancelled { noteWaiter = nil }
                    guard !Task.isCancelled, noteStopping else { return }
                    noteStopping = false
                    // Still running after the wait: say so, as for any second Generate.
                    if integrations.inferenceQueue.hasJob(labelled: jobLabel) {
                        alert(.message("A note for this session is already being written."))
                    } else {
                        generate()
                    }
                }
            } else {
                alert(.message("A note for this session is already being written."))
            }
            return
        }
        noteStopping = false
        let format = settings.progressNoteFormat
        generatingFormat = format
        noteHighWater = ProgressHighWater()
        let verbosity = settings.summaryVerbosity
        let instructions = settings.noteInstructions[format.rawValue]
        // Snapshot the inputs now; the request itself is only made when the
        // queue starts this job (it may be waiting behind a chat answer).
        let service = integrations.makeAssistantService(report: runner.reporter, clientName: patient.name)
        let transcript = material.transcriptText
        let notes = material.myNotes
        let sessionComments = settings.includeCommentsInDrafts ? material.comments : []
        let patientBackground = settings.includePatientBackground ? patient.aiBackgroundBlock : ""
        let effort = settings.noteEffort
        let riskPhrases = settings.riskPhrases
        let model = service.model
        let produced = CoverageBox()
        let patient = patient!
        let session = session!
        let runner = runner
        runner.start(
            queue: integrations.inferenceQueue,
            kind: .note,
            label: jobLabel,
            readTitle: "Reading the session",
            writeTitle: "Writing the note",
            makeStream: { [self] in
                // The job has started: drop the old note so the pane can show
                // progress until the first token.
                if settings.progressNoteFormat == format { summaryText = ""; noteCoverage = nil }
                return LongSessionNote.stream(
                    format: format,
                    transcript: transcript,
                    notes: notes,
                    comments: sessionComments,
                    patientBackground: patientBackground,
                    verbosity: verbosity,
                    instructions: instructions,
                    effort: effort,
                    riskPhrases: riskPhrases,
                    service: service,
                    builder: integrations.digests,
                    sessionID: session.id,
                    loadDigest: {
                        await Task.detached { store.digest(for: patient, session: session, model: model) }.value
                    },
                    saveDigest: { try store.saveDigest($0, for: patient, session: session) },
                    sectionCache: .store(store, patient: patient, session: session),
                    live: { started, change in runner.update(started: started, change) },
                    coverage: { [self] in
                        produced.text = $0
                        if settings.progressNoteFormat == format { noteCoverage = $0 }
                    }
                )
            },
            onReveal: { [self] text in
                if settings.progressNoteFormat == format { summaryText = text }
            },
            onError: { [self] error in
                if let incident = AIEngineIncident.from(error: error) {
                    alert(.engine(incident, kind: .note, retry: { [weak self] in self?.generate() }))
                } else {
                    alert(.message(error.localizedDescription))
                }
                // The reveal blanked the pane; put back what is actually saved.
                if settings.progressNoteFormat == format {
                    summaryText = savedNote(for: format)
                    noteCoverage = savedCoverage(for: format)
                }
            },
            onFinish: { [self] raw in
                // Save the tidied text, so copy, export and edit see the same
                // paragraphs and labels the pane shows.
                let final = SpeakerCodes.scrub(NoteMarkdown.tidy(raw), clientName: patient.name)
                // Stopped part-way: say the saved note is only what was written so far.
                if noteStopping, !final.isEmpty, !(produced.text ?? "").contains(LongSessionNote.CheckOutcome.stopped.text) {
                    produced.text = [produced.text, LongSessionNote.stoppedEarlyText].compactMap { $0 }.joined(separator: " ")
                    if settings.progressNoteFormat == format { noteCoverage = produced.text }
                }
                guard !final.isEmpty else {
                    // Stopped before the first token, or empty output: the pane
                    // was cleared at start, so put back what is saved.
                    if settings.progressNoteFormat == format {
                        summaryText = savedNote(for: format)
                        noteCoverage = savedCoverage(for: format)
                    }
                    return
                }
                if settings.progressNoteFormat == format { summaryText = final }
                do {
                    try store.saveGeneratedNote(final, for: patient, session: session, format: format, generatedFromTranscript: transcript, coverage: produced.text)
                } catch {
                    alert(.message(error.localizedDescription))
                    if settings.progressNoteFormat == format {
                        summaryText = savedNote(for: format)
                        noteCoverage = savedCoverage(for: format)
                    }
                    return
                }
                // Record which transcript this note came from (the snapshot the
                // request used, not whatever the transcript is by now).
                if settings.progressNoteFormat == format {
                    refreshHasPreviousNote()
                    noteFingerprint = NoteFreshness.fingerprint(of: transcript)
                    // The format may have been switched away and back during the run.
                    noteCoverage = savedCoverage(for: format)
                }
                sessionUpdated()
                let notifier = integrations.makeNotifier()
                let policy = PatientLabel.Policy.current(showFullName: settings.notificationsShowPatientNames)
                Task {
                    await notifier.post(
                        SessionNotifications.summaryReady(patientName: patient.name, date: session.date, policy: policy))
                }
            }
        )
    }
}
