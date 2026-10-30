@testable import Aletheia
import AppKit
import Foundation
import XCTest

// MARK: - Subjects

/// What a person said in a session, in order.
enum Said {
    case you(String)
    case client(String)
}

/// A patient's session with its transcript on disk.
struct StoredSession {
    let patient: Patient
    let session: SessionRecord
}

/// An alert the screen would show for a failed request.
struct ShownAlert {
    let title: String
    let message: String
    /// The buttons it offers besides dismissing it.
    let offers: [String]
    fileprivate let again: (() -> Void)?
}

/// Everything on the Notes tab at one moment.
struct NotePane {
    let text: String
    /// "No SOAP note yet" and its button, when the pane is empty and idle.
    let emptyTitle: String?
    let generateButton: String?
    let isWriting: Bool
    let isWaiting: Bool
    let waitingStatus: String?
    let statusLine: String?
    let offersStop: Bool
    let offersCancel: Bool
    let coverage: String?
    let outdatedMessage: String?
    let offersRestorePrevious: Bool
    let asksBeforeReplacing: Bool
}

/// What the Length button's menu offers.
struct LengthMenu {
    let label: String
    let lengths: [String]
    let efforts: [String]
}

/// What a Copy put on the pasteboard, and what the button then said.
struct CopiedNote {
    let plain: String
    let rich: NSAttributedString?
    let buttonTitle: String
}

/// Everything on a session's Ask tab at one moment.
struct AskPane {
    struct Bubble: Equatable {
        enum Who: Equatable { case you, assistant, summary }
        let who: Who
        let text: String
    }
    let bubbles: [Bubble]
    let isAnswering: Bool
    let isWaiting: Bool
    let waitingStatus: String?
    let offersStop: Bool
    let offersCancel: Bool
    /// The "Read:" line and other caveats under the answer.
    let notices: [String]
    /// The line over the bar while an answer is being prepared, "Reading the session · part 2 of 3 · 0:04".
    let statusLine: String?
    /// Whether the conversation can be compacted from the effort bar.
    let offersCompact: Bool
    /// The caution under the conversation.
    let accuracyNotice: String
    /// The prompt over an empty conversation.
    let emptyTitle: String?

    var questions: [String] { bubbles.filter { $0.who == .you }.map(\.text) }
    var answers: [String] { bubbles.filter { $0.who == .assistant }.map(\.text) }
}

// MARK: - The desk

/// The AI side of the app over the real stores, queue, prompts and settings, with
/// the model swapped for one the test steers.
@MainActor
final class AssistantDesk {
    let app: InProcessDriver
    let model: SteeredModel
    let notifier = QuietNotifier()
    let integrations: Integrations

    fileprivate init(app: InProcessDriver, model: SteeredModel) {
        self.app = app
        self.model = model
        let clock = app.clock
        let integrations = Integrations(
            settings: app.settings, engine: model, notifier: notifier, now: { clock.now })
        self.integrations = integrations
        // At teardown: let held answers finish, then stop the scheduler and the
        // queue together (as quitting does) and wait for both.
        app.stopOnShutDown {
            model.releaseEverything()
            async let scheduler: Void = integrations.digestScheduler.shutDown()
            async let queue: Void = integrations.inferenceQueue.shutDown()
            _ = await (scheduler, queue)
        }
    }

    var settings: AppSettings { app.settings }
    var store: Store {
        get throws { try XCTUnwrap(app.appModel.store, "the data folder is not open") }
    }

    // MARK: Scene

    /// A session of `patient` whose transcript is the conversation `said`.
    func session(of patient: Patient, saying said: [Said], daysAgo: Int = 0) throws -> StoredSession {
        try session(of: patient, transcript: Self.transcript(said), daysAgo: daysAgo)
    }

    func session(of patient: Patient, transcript: String, daysAgo: Int = 0) throws -> StoredSession {
        let store = try store
        let date = app.clock.now.addingTimeInterval(-Double(daysAgo) * 86_400)
        let created = try store.createSession(for: patient, on: date)
        try store.saveTranscript(transcript, for: patient, session: created)
        app.appModel.refreshPatients()
        return StoredSession(patient: patient, session: try listed(created, of: patient))
    }

    /// A transcript far longer than any Mac here can read in one go.
    static func longTranscript(characters: Int = 260_000) -> String {
        var lines: [String] = []
        var size = 0
        var index = 0
        while size < characters {
            let speaker = index % 2 == 0 ? "Y" : "C"
            let line = String(format: "[%02d:%02d] %@: This is line %d about how the week went at work and at home.",
                              (index / 60) % 100, index % 60, speaker, index)
            lines.append(line)
            size += line.count + 1
            index += 1
        }
        return lines.joined(separator: "\n")
    }

    /// A transcript of a `minutes`-long session, one exchange every half minute, that mentions `topic` throughout.
    static func transcript(minutes: Int, about topic: String) -> String {
        (0..<(minutes * 2)).map { index in
            let stamp = String(format: "[%02d:%02d]", (index * 30) / 60, (index * 30) % 60)
            let speaker = index % 2 == 0 ? "Y" : "C"
            return "\(stamp) \(speaker): Tell me more about \(topic) this week, number \(index)."
        }.joined(separator: "\n")
    }

    /// Writes `text` in the session's My Notes, which saves as it goes.
    func writeInMyNotes(_ text: String, for stored: StoredSession) {
        app.appModel.saveNote(sessionID: stored.session.id, text: text)
    }

    static func transcript(_ said: [Said]) -> String {
        said.enumerated().map { index, line in
            let stamp = String(format: "[%02d:%02d]", (index * 12) / 60, (index * 12) % 60)
            switch line {
            case .you(let text): return "\(stamp) Y: \(text)"
            case .client(let text): return "\(stamp) C: \(text)"
            }
        }.joined(separator: "\n")
    }

    func addComment(_ body: String, to stored: StoredSession) {
        _ = app.appModel.addComment(sessionID: stored.session.id, quotedText: "", body: body, anchorSeconds: nil, quoteStart: nil)
    }

    func backgroundOf(_ patient: Patient, is text: String) {
        app.appModel.updatePatient(id: patient.id) { $0.clinicalHistory = text }
    }

    func listed(_ session: SessionRecord, of patient: Patient) throws -> SessionRecord {
        let all = try store.listSessions(for: patient)
        return try XCTUnwrap(all.first { $0.id == session.id }, "session \(session.folderName) is gone")
    }

    // MARK: Tabs

    func notesTab(of stored: StoredSession) -> NotesTab { NotesTab(desk: self, stored: stored) }
    func askTab(of stored: StoredSession) -> AskTab { AskTab(desk: self, stored: stored) }
    func patientChat(of patient: Patient) -> PatientChatTab { PatientChatTab(desk: self, patient: patient) }

    /// What the screen would put in front of a session's note and chat prompts.
    fileprivate func material(of stored: StoredSession) throws -> SessionInputs {
        let inputs = SessionInputs()
        try reload(inputs, of: stored)
        return inputs
    }

    fileprivate func reload(_ inputs: SessionInputs, of stored: StoredSession) throws {
        inputs.transcriptText = try store.readTranscript(for: stored.patient, session: stored.session) ?? ""
        inputs.myNotes = app.appModel.commentStore?.note(sessionID: stored.session.id) ?? ""
        inputs.comments = app.appModel.commentStore?.comments(sessionID: stored.session.id) ?? []
    }

    fileprivate static func shown(_ alert: AIAlert) -> ShownAlert {
        switch alert {
        case .message(let text):
            return ShownAlert(title: "Something went wrong", message: text, offers: [], again: nil)
        case .engine(let incident, _, let retry):
            return ShownAlert(
                title: incident.problem.title, message: incident.problem.message,
                offers: [incident.problem.actionTitle], again: retry)
        }
    }

    /// Alerts the screen has shown, and asking again after the cause is fixed.
    func askAgain(_ alert: ShownAlert) throws {
        let again = try XCTUnwrap(alert.again, "the alert has nothing to retry")
        again()
    }

    // MARK: Waiting

    /// Waits for `condition`; on a timeout the error says what `describe` saw,
    /// or else what the model was asked and what it holds.
    func waitFor(_ what: String, within seconds: TimeInterval = 10,
                 describe: (@MainActor () -> String)? = nil, _ condition: @MainActor () -> Bool) async throws {
        let model = self.model
        try await eventually(within: seconds, what, describe: describe ?? {
            "model asked \(model.startedCount), finished \(model.finishedCount), held \(model.heldCount)"
        }) { condition() }
    }
}

// MARK: - Notes tab

/// A session's Notes tab, on the real note model.
@MainActor
final class NotesTab {
    private let desk: AssistantDesk
    private let stored: StoredSession
    private let inputs: SessionInputs
    let model = SessionNoteModel()
    private(set) var alerts: [ShownAlert] = []

    fileprivate init(desk: AssistantDesk, stored: StoredSession) {
        self.desk = desk
        self.stored = stored
        inputs = (try? desk.material(of: stored)) ?? SessionInputs()
        model.configure(
            appModel: desk.app.appModel, integrations: desk.integrations, settings: desk.settings,
            patient: stored.patient, session: stored.session, material: inputs)
        model.alert = { [weak self] in self?.alerts.append(AssistantDesk.shown($0)) }
        model.showSaved(for: desk.settings.progressNoteFormat)
    }

    // MARK: Actions

    func pick(_ format: NoteFormat) {
        desk.settings.progressNoteFormat = format.progress
        model.showSaved(for: format.progress)
    }

    func generate() { model.requestGenerate() }
    func stop() { model.stop() }
    func cancelWaiting() { model.stop() }
    func confirmReplacing() { model.confirmRegenerate = false; model.generate() }
    func restorePrevious() { model.restorePrevious() }

    /// Edits the shown note to `text` and saves it.
    func edit(to text: String) {
        model.beginEditing()
        model.noteDraft = text
        model.saveEdited()
    }

    func changeTranscript(to text: String) throws {
        try desk.store.saveTranscript(text, for: stored.patient, session: stored.session)
        try desk.reload(inputs, of: stored)
    }

    /// Types `text` into My Notes, which saves as it goes.
    func typeInMyNotes(_ text: String) {
        desk.app.appModel.saveNote(sessionID: stored.session.id, text: text)
        inputs.myNotes = text
    }

    func saveOwnInstructions(_ text: String, for format: NoteFormat) {
        desk.settings.setNoteInstructions(text, for: format.progress)
    }

    func resetInstructionsToDefault(for format: NoteFormat) {
        desk.settings.setNoteInstructions(Prompts.defaultInstructions(for: format.progress), for: format.progress)
    }

    /// Writes a note at `length` and `effort` and waits for it to end, replacing any note already there.
    func generate(_ length: NoteLength, at effort: Effort) async throws {
        chooseLength(length.setting)
        chooseEffort(effort)
        model.requestGenerate()
        if model.confirmRegenerate { confirmReplacing() }
        try await waitUntilIdle()
    }

    /// What the Notes picker offers, in order.
    var pickerChoices: [String] { NotesPane.all.map(\.label) }

    /// The instructions the next note of `format` is written with.
    func instructionsInEffect(for format: NoteFormat) -> String {
        desk.settings.noteInstructions[format.progress.rawValue] ?? Prompts.defaultInstructions(for: format.progress)
    }

    /// Whether `format` has its own instructions saved.
    func hasOwnInstructions(for format: NoteFormat) -> Bool {
        desk.settings.noteInstructions[format.progress.rawValue] != nil
    }

    /// Presses Copy, and returns what went on the pasteboard.
    func copy() -> CopiedNote {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        model.copyNote(to: pasteboard)
        let rtf = pasteboard.data(forType: .rtf)
        return CopiedNote(
            plain: pasteboard.string(forType: .string) ?? "",
            rich: rtf.flatMap { try? NSAttributedString(
                data: $0, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) },
            buttonTitle: model.copyFeedback.title)
    }

    /// What the Length button opens.
    var lengthMenu: LengthMenu {
        LengthMenu(
            label: NoteWords.lengthLabel(length: desk.settings.summaryVerbosity, effort: desk.settings.noteEffort),
            lengths: NoteWords.lengthChoices, efforts: NoteWords.effortChoices)
    }

    func chooseLength(_ length: SummaryVerbosity) { desk.settings.summaryVerbosity = length }
    func chooseEffort(_ effort: Effort) { desk.settings.noteEffort = effort.setting }
    var effort: AnswerEffort { desk.settings.noteEffort }

    // MARK: Reading

    var pane: NotePane {
        let streaming = model.runner.isStreaming
        let queued = model.runner.isQueued
        let idleAndEmpty = model.summaryText.isEmpty && !streaming && !queued
        let format = desk.settings.progressNoteFormat
        return NotePane(
            text: model.summaryText,
            emptyTitle: idleAndEmpty ? NoteWords.emptyTitle(format: format) : nil,
            generateButton: idleAndEmpty ? NoteWords.generateButton(format: format) : nil,
            isWriting: streaming, isWaiting: queued,
            waitingStatus: model.runner.queuedStatus,
            statusLine: streaming
                ? NoteProgress.statusLine(
                    title: NoteProgress.title(for: model.generatingFormat), model.runner.progress, now: Date())
                : nil,
            offersStop: streaming, offersCancel: queued,
            coverage: model.noteCoverage,
            outdatedMessage: model.noteIsOutdated ? NoteWords.outdatedMessage : nil,
            offersRestorePrevious: model.hasPreviousNote,
            asksBeforeReplacing: model.confirmRegenerate)
    }

    /// The step the run says it is on ("Processing transcript. Reading part 2 of 5").
    var readTitle: String { model.runner.progress.readTitle }

    var myNotesOnDisk: String { desk.app.appModel.commentStore?.note(sessionID: stored.session.id) ?? "" }

    func savedNote(_ format: ProgressNoteFormat) -> String { model.savedNote(for: format) }

    // MARK: Waiting

    /// The pane in a line, for a timeout's message.
    private func describePane() -> String {
        let now = pane
        return "status \(String(describing: now.statusLine)), waiting: \(now.isWaiting) \(String(describing: now.waitingStatus)), "
            + "writing: \(now.isWriting), text: \"\(now.text.prefix(120))\", alerts: \(alerts.map(\.title)), "
            + "model asked \(desk.model.startedCount), held \(desk.model.heldCount)"
    }

    func waitUntilIdle() async throws {
        try await desk.waitFor("the note to finish", within: 30, describe: describePane) {
            !self.model.runner.isStreaming && !self.model.runner.isQueued
        }
    }

    func waitForStatus(containing text: String) async throws {
        try await desk.waitFor("the status to mention \"\(text)\"", describe: describePane) {
            self.pane.statusLine?.contains(text) == true
        }
    }

    func waitUntilWaiting() async throws {
        try await desk.waitFor("the note to wait its turn") { self.model.runner.isQueued }
    }

    func waitUntilWriting() async throws {
        try await desk.waitFor("the note to start", describe: describePane) { self.model.runner.isStreaming }
    }

    func waitUntilShowing(_ text: String) async throws {
        try await desk.waitFor("the pane to show \"\(text)\"", describe: describePane) { self.model.summaryText.contains(text) }
    }

    func waitForAlert() async throws -> ShownAlert {
        try await desk.waitFor("an alert", describe: describePane) { !self.alerts.isEmpty }
        return alerts[alerts.count - 1]
    }
}

// MARK: - Ask tab

/// A session's Ask tab, on the real chat model.
@MainActor
final class AskTab {
    private let desk: AssistantDesk
    private let stored: StoredSession
    private let inputs: SessionInputs
    let model = SessionChatModel()
    private(set) var alerts: [ShownAlert] = []

    fileprivate init(desk: AssistantDesk, stored: StoredSession) {
        self.desk = desk
        self.stored = stored
        inputs = (try? desk.material(of: stored)) ?? SessionInputs()
        model.configure(
            appModel: desk.app.appModel, integrations: desk.integrations, settings: desk.settings,
            patient: stored.patient, session: stored.session, material: inputs)
        model.alert = { [weak self] in self?.alerts.append(AssistantDesk.shown($0)) }
        model.load()
    }

    func ask(_ question: String) { model.send(question) }
    func stop() { model.stop() }
    func cancelWaiting() { model.stop() }
    func compact() { model.compact("") }
    func chooseEffort(_ effort: Effort) { desk.settings.sessionChatEffort = effort.setting }
    var effort: AnswerEffort { desk.settings.sessionChatEffort }

    var pane: AskPane {
        AskPane(
            bubbles: model.messages.map {
                AskPane.Bubble(who: AskTab.who($0.role), text: $0.text)
            },
            isAnswering: model.runner.isStreaming,
            isWaiting: model.runner.isQueued,
            waitingStatus: model.runner.queuedStatus,
            offersStop: model.runner.isStreaming,
            offersCancel: model.runner.isQueued,
            notices: model.notices,
            statusLine: model.runner.isStreaming
                ? AIProgressFormat.statusLine(model.runner.progress, now: Date()) : nil,
            offersCompact: ChatMemory.hasHistory(model.messages),
            accuracyNotice: ChatPaneView.accuracyNotice,
            emptyTitle: model.messages.isEmpty ? ChatWords.emptyTitle(about: ChatWords.thisSession) : nil)
    }

    fileprivate static func who(_ role: ChatRole) -> AskPane.Bubble.Who {
        switch role {
        case .user: return .you
        case .assistant: return .assistant
        case .summary: return .summary
        }
    }

    var storedConversation: [ChatMessage] {
        ((try? desk.store)?.loadSessionChat(for: stored.patient, session: stored.session)) ?? []
    }

    /// The pane in a line, for a timeout's message.
    private func describePane() -> String {
        let now = pane
        return "status \(String(describing: now.statusLine)), waiting: \(now.isWaiting), answering: \(now.isAnswering), "
            + "bubbles: \(now.bubbles.map { "\($0.who): \($0.text.prefix(60))" }), alerts: \(alerts.map(\.title)), "
            + "model asked \(desk.model.startedCount), held \(desk.model.heldCount)"
    }

    func waitForStatus(startingWith text: String) async throws {
        try await desk.waitFor("the status to read \"\(text)…\"", describe: describePane) {
            self.pane.statusLine?.hasPrefix(text) == true
        }
    }

    func waitUntilAnswering() async throws {
        try await desk.waitFor("the answer to start", describe: describePane) { self.model.runner.isStreaming }
    }

    func waitUntilIdle() async throws {
        try await desk.waitFor("the answer to finish", within: 30, describe: describePane) {
            !self.model.runner.isStreaming && !self.model.runner.isQueued && !self.model.isSending
        }
    }

    func waitForAlert() async throws -> ShownAlert {
        try await desk.waitFor("an alert", describe: describePane) { !self.alerts.isEmpty }
        return alerts[alerts.count - 1]
    }

    func waitUntilShowing(_ text: String) async throws {
        try await desk.waitFor("the conversation to show \"\(text)\"", describe: describePane) {
            self.model.messages.contains { $0.text.contains(text) }
        }
    }
}

// MARK: - Patient chat

/// The patient-wide chat ("Ask about <name>"), on the real patient chat model.
@MainActor
final class PatientChatTab {
    private let desk: AssistantDesk
    private let patient: Patient
    let model = PatientChatModel()
    private(set) var alerts: [ShownAlert] = []

    fileprivate init(desk: AssistantDesk, patient: Patient) {
        self.desk = desk
        self.patient = patient
        model.configure(
            appModel: desk.app.appModel, integrations: desk.integrations, settings: desk.settings, patient: patient)
        model.alert = { [weak self] in self?.alerts.append(AssistantDesk.shown($0)) }
        model.reloadThreads()
    }

    // MARK: Actions

    func startNewThread() { model.startNewThread() }
    func ask(_ question: String) { model.send(question) }
    func stop() { model.stop() }
    func cancelWaiting() { model.stop() }
    func compact() { model.compact("") }
    func rename(_ thread: ChatThread, to title: String) { model.rename(thread, to: title) }
    func delete(_ thread: ChatThread) { model.delete(thread) }
    func chooseEffort(_ effort: Effort) { desk.settings.patientChatEffort = effort.setting }
    var effort: AnswerEffort { desk.settings.patientChatEffort }

    // MARK: Reading

    var threadTitles: [String] { model.threads.map(\.displayTitle) }

    var pane: AskPane {
        AskPane(
            bubbles: model.messages.map {
                AskPane.Bubble(who: AskTab.who($0.role), text: $0.text)
            },
            isAnswering: model.runner.isStreaming,
            isWaiting: model.runner.isQueued,
            waitingStatus: model.runner.queuedStatus,
            offersStop: model.runner.isStreaming,
            offersCancel: model.runner.isQueued,
            notices: model.notices,
            statusLine: model.searchingNotice
                ?? (model.runner.isStreaming ? AIProgressFormat.statusLine(model.runner.progress, now: Date()) : nil),
            offersCompact: ChatMemory.hasHistory(model.messages),
            accuracyNotice: ChatPaneView.accuracyNotice,
            emptyTitle: model.messages.isEmpty ? ChatWords.emptyTitle(about: patient.name) : nil)
    }

    /// Whether the window for this patient would show "no longer available".
    var windowShowsPatientGone: Bool {
        PatientChatWindow.patient(id: patient.id, in: desk.app.appModel.patients) == nil
    }

    // MARK: Waiting

    func waitUntilIdle() async throws {
        try await desk.waitFor("the answer to finish", within: 30) {
            !self.model.isSending && !self.model.runner.isStreaming && !self.model.runner.isQueued
        }
    }

    func waitUntilShowing(_ text: String) async throws {
        try await desk.waitFor("the conversation to show \"\(text)\"") {
            self.model.messages.contains { $0.text.contains(text) }
        }
    }
}

// MARK: - Given

extension Given {
    /// The AI side of the app, with the model as the test steers it.
    func assistantDesk(model: SteeredModel = SteeredModel()) -> AssistantDesk {
        AssistantDesk(app: app, model: model)
    }
}
