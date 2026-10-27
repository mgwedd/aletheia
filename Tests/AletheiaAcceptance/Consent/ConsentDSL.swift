@testable import Aletheia
import Foundation
import PDFKit
import XCTest

// MARK: - Subjects

/// The Record consent sheet, as the session screen and Import Audio… show it.
/// It holds the same `ConsentCapture` the sheet binds to.
@MainActor
final class ConsentSheet {
    let visit: PatientSession
    let purpose: ConsentSheetPurpose
    let policy: ConsentPolicy
    let openedAt: Date
    var capture: ConsentCapture

    init(visit: PatientSession, purpose: ConsentSheetPurpose, policy: ConsentPolicy, openedAt: Date) {
        self.visit = visit
        self.purpose = purpose
        self.policy = policy
        self.openedAt = openedAt
        capture = ConsentCapture(openedAt: openedAt)
    }

    var title: String { RecordingConsent.sheetTitle }
    var explanation: String { RecordingConsent.sheetExplanation(policy) }
    var whoOptions: [String] { ConsentParty.allCases.map(\.title) }
    var howOptions: [String] { ConsentMethod.allCases.map(\.title) }
    var confirmTitle: String { purpose.confirmTitle }
    var canConfirm: Bool { capture.isComplete }
    var asksForName: Bool { capture.party.needsName }

    func choose(_ party: ConsentParty) { capture.party = party }
    func choose(_ method: ConsentMethod) { capture.method = method }
    func typeName(_ name: String) { capture.name = name }
    func setWhen(_ date: Date) { capture.consentedAt = date }
    func tickConfirmation(_ on: Bool = true) { capture.confirmed = on }
}

/// What pressing Record Session (or Import Audio…) led to.
struct ConsentGate {
    /// The sheet, when the session must ask first.
    let sheet: ConsentSheet?
    /// Whether the file picker opened (Import Audio… only).
    var pickerOpened = false
}

/// The menu bar panel with a patient chosen.
@MainActor
final class MenuBarConsentPanel {
    let patient: Patient
    let needsConsent: Bool
    var capture = ConsentCapture()

    init(patient: Patient, needsConsent: Bool) {
        self.patient = patient
        self.needsConsent = needsConsent
    }

    /// Start recording is enabled.
    var canStart: Bool { RecordingConsent.menuBarProblem(needsConsent: needsConsent, capture: capture) == nil }
}

/// Settings > Apply to Patients…, over every patient.
@MainActor
final class ApplyToPatientsSheet {
    let patients: [Patient]
    var edit = ConsentPolicyBulkEdit()

    init(patients: [Patient]) { self.patients = patients }

    var canApply: Bool { edit.canApply }
    var choices: [String] { ConsentPolicyChoice.allCases.map(\.title) }
    func select(_ patient: Patient) { edit.toggle(patient.id) }
    func selectAll() { edit.selectAll(true, of: patients.map(\.id)) }
    func choose(_ choice: ConsentPolicyChoice) { edit.choice = choice }
}

/// The session's consent as rendered in one export.
struct ConsentInExport {
    let what: String
    let text: String
}

/// A session with a saved, signed note.
struct SignedVisit {
    let visit: PatientSession
}

/// A save that was tried and what it said.
struct ConsentSaveAttempt {
    let error: Error?
    let recordBefore: ConsentRecord?
    let recordAfter: ConsentRecord?
}

/// The consent file on disk, before and after a relaunch.
struct SealedConsent {
    let rawBytes: Data
    let written: ConsentRecord
    let readBack: ConsentRecord?
}

// MARK: - Given

extension Given {
    /// Jane Doe and Adam Lee, each with an empty session, FileVault on.
    func janeAndAdamWithSessions() async throws -> (jane: PatientSession, adam: PatientSession) {
        fileVaultIsOn()
        let jane = try await aPatientWithASession(named: "Jane Doe")
        let adam = try await aPatientWithASession(named: "Adam Lee")
        return (jane, adam)
    }

    /// Settings > General > Recording consent.
    func recordingConsentDefault(_ policy: ConsentPolicy) { app.settings.recordingConsentPolicy = policy }

    /// The activity log signs with a test key instead of the real Keychain, and
    /// settings changes reach it as they do in the app.
    func activityLogIsOn() {
        let model = app.appModel
        model.auditKeyProvider = { SecurityFixtures.auditKey }
        model.rebuildStore()
        app.settings.onAuditedChange = { [weak model] in model?.recordAudit(.securitySettingChanged, detail: $0) }
    }

    /// Consent recorded for `visit` through the sheet: the patient, verbally.
    @discardableResult
    func consentRecorded(for visit: PatientSession, method: ConsentMethod = .verbal) throws -> ConsentRecord {
        var capture = ConsentCapture(openedAt: Date())
        capture.method = method
        capture.confirmed = true
        return try app.appModel.recordConsent(capture, patient: visit.patient, session: visit.session)
    }

    /// The session's SOAP note saved and signed.
    func signedNote(in visit: PatientSession) throws -> SignedVisit {
        let store = try XCTUnwrap(app.appModel.store)
        try store.saveNote("S: Feeling better.\nO: Calm.\nA: Improving.\nP: Continue.", for: visit.patient, session: visit.session, format: .soap)
        try store.signNote(for: visit.patient, session: visit.session, format: .soap)
        return SignedVisit(visit: visit)
    }
}

// MARK: - When

extension When {
    private func latest(_ patient: Patient) -> Patient {
        app.appModel.patients.first { $0.id == patient.id } ?? patient
    }

    /// Record Session: the sheet when the session must ask, else the recorder starts.
    func pressRecordSession(_ visit: PatientSession, on bench: RecordingBench) async -> ConsentGate {
        let model = app.appModel
        if model.needsRecordingConsent(patient: visit.patient, session: visit.session) {
            return ConsentGate(sheet: ConsentSheet(
                visit: visit, purpose: .record, policy: model.consentPolicy(for: visit.patient), openedAt: Date()))
        }
        await bench.pressRecord(patient: visit.patient, session: visit.session)
        return ConsentGate(sheet: nil)
    }

    /// Import Audio…: the sheet when the session must ask, else the file picker.
    func pressImportAudio(_ visit: PatientSession) -> ConsentGate {
        let model = app.appModel
        if model.needsRecordingConsent(patient: visit.patient, session: visit.session) {
            return ConsentGate(sheet: ConsentSheet(
                visit: visit, purpose: .importAudio, policy: model.consentPolicy(for: visit.patient), openedAt: Date()))
        }
        return ConsentGate(sheet: nil, pickerOpened: true)
    }

    /// The sheet's confirm button: saves consent, then records or opens the picker.
    func confirm(_ sheet: ConsentSheet, on bench: RecordingBench? = nil) async throws -> ConsentGate {
        guard sheet.canConfirm else { return ConsentGate(sheet: sheet) }
        try app.appModel.recordConsent(sheet.capture, patient: sheet.visit.patient, session: sheet.visit.session)
        switch sheet.purpose {
        case .record:
            if let bench { await bench.pressRecord(patient: sheet.visit.patient, session: sheet.visit.session) }
            return ConsentGate(sheet: nil)
        case .importAudio:
            return ConsentGate(sheet: nil, pickerOpened: true)
        case .change:
            return ConsentGate(sheet: nil)
        }
    }

    /// The consent line on the session screen.
    func consentLine(of visit: PatientSession) throws -> String {
        RecordingConsent.sessionLine(try app.appModel.consentStatus(patient: latest(visit.patient), session: visit.session))
    }

    /// The menu bar panel with `patient` chosen.
    func chooseInMenuBar(_ patient: Patient) -> MenuBarConsentPanel {
        MenuBarConsentPanel(patient: patient, needsConsent: app.appModel.needsRecordingConsent(patient: patient, session: nil))
    }

    /// The panel's Start recording, step for step: the consent check, the
    /// FileVault gate, a new session, its consent record, then the recorder.
    func startRecording(from panel: MenuBarConsentPanel, on bench: RecordingBench) async throws -> MenuBarStart {
        let model = app.appModel
        let store = try XCTUnwrap(model.store)
        let before = (try? store.listSessions(for: panel.patient).count) ?? 0
        func result(_ session: SessionRecord?, _ problem: String?) -> MenuBarStart {
            MenuBarStart(session: session, problem: problem, sessionsBefore: before,
                         sessionsAfter: (try? store.listSessions(for: panel.patient).count) ?? 0)
        }
        if let problem = RecordingConsent.menuBarProblem(needsConsent: panel.needsConsent, capture: panel.capture) {
            return result(nil, problem)
        }
        model.refreshDiskEncryption()
        guard PHIEntryGate.allowsNewPHI(diskEncrypted: model.diskEncrypted) else { return result(nil, PHIEntryGate.blockedMessage) }
        guard let session = model.startNewSession(for: panel.patient) else { return result(nil, "no session") }
        if panel.needsConsent {
            try model.recordConsent(panel.capture, patient: panel.patient, session: session)
        }
        let problem = await bench.recorder.start(
            micURL: store.micRecordingURL(for: panel.patient, session: session),
            callURL: store.callRecordingURL(for: panel.patient, session: session),
            context: bench.context(for: panel.patient, session: session),
            protector: model.currentProtector)
        return result(session, problem)
    }

    /// Settings > General > Recording consent.
    func setRecordingConsentDefault(_ policy: ConsentPolicy) { app.settings.recordingConsentPolicy = policy }

    func openApplyToPatients() -> ApplyToPatientsSheet { ApplyToPatientsSheet(patients: app.appModel.patients) }

    func apply(_ sheet: ApplyToPatientsSheet) {
        guard sheet.canApply else { return }
        app.appModel.setConsentPolicy(sheet.edit.choice.policy, forPatients: sheet.edit.selected)
    }

    /// The policy each patient's profile editor shows.
    func profileConsentChoice(of patient: Patient) -> ConsentPolicyChoice {
        PatientProfileDraft(patient: latest(patient), showsMedications: false).recordingConsent
    }

    func activityLog() throws -> [AuditEvent] {
        try XCTUnwrap(app.appModel.audit, "there is no activity log").entries()
    }

    /// The session exported as PDF, Word and Markdown, each read back as text.
    func exportSession(_ visit: PatientSession) throws -> [ConsentInExport] {
        let store = try XCTUnwrap(app.appModel.store)
        let markdown = store.exportSessionMarkdown(patient: latest(visit.patient), session: visit.session)
        return try [ExportFormat.pdf, .word, .markdown].map { format in
            let data = try XCTUnwrap(ExportRenderer.data(for: format, document: ExportDocument(markdown: markdown)), "nothing rendered for \(format.title)")
            let url = app.root.deletingLastPathComponent().appendingPathComponent("consent-\(UUID().uuidString).\(format.fileExtension)")
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            return ConsentInExport(what: format.title, text: Self.readBack(url, format: format))
        }
    }

    /// File > Export All Records…, with the session's consent file read back.
    func exportAllRecords(consentOf visit: PatientSession) throws -> ConsentInExport {
        let store = try XCTUnwrap(app.appModel.store)
        let destination = app.root.deletingLastPathComponent().appendingPathComponent("consent-all-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try AllRecordsExport.write(
            from: try StoreAllRecordsSource(store: store), to: destination, exportedOn: Date(),
            progress: { _, _ in }, isCancelled: { false })
        let files = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        let consent = files.first { $0.lastPathComponent == Copy.consentArchiveFile }
        let text = consent.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return ConsentInExport(what: "all records", text: text)
    }

    /// Records consent again on a session whose note is signed.
    func saveConsentAgain(_ signed: SignedVisit) throws -> ConsentSaveAttempt {
        let visit = signed.visit
        let before = try app.appModel.consentRecord(patient: visit.patient, session: visit.session)
        var capture = ConsentCapture(openedAt: Date())
        capture.method = .written
        capture.confirmed = true
        var thrown: Error?
        do { try app.appModel.recordConsent(capture, patient: visit.patient, session: visit.session) } catch { thrown = error }
        let after = try app.appModel.consentRecord(patient: visit.patient, session: visit.session)
        return ConsentSaveAttempt(error: thrown, recordBefore: before, recordAfter: after)
    }

    func canChangeConsent(_ signed: SignedVisit) -> Bool {
        app.appModel.canChangeConsent(patient: signed.visit.patient, session: signed.visit.session)
    }

    /// Quits and reopens over the same folder, then reads the consent back.
    func quitAndReopen(reading written: ConsentRecord, of visit: PatientSession) throws -> SealedConsent {
        let store = try XCTUnwrap(app.appModel.store)
        let file = store.sessionDir(for: visit.patient, session: visit.session).appendingPathComponent(Store.consentFileName)
        let raw = try Data(contentsOf: file)
        app.relaunch(tier: app.tier)
        if app.appModel.store == nil { try? app.encryption.unlock(passphrase: EncryptionFixtures.passphrase) }
        let readBack = try app.appModel.consentRecord(patient: visit.patient, session: visit.session)
        return SealedConsent(rawBytes: raw, written: written, readBack: readBack)
    }

    fileprivate static func readBack(_ url: URL, format: ExportFormat) -> String {
        switch format {
        case .pdf: return PDFDocument(url: url)?.string ?? ""
        case .markdown: return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        case .word:
            guard let data = try? Data(contentsOf: url),
                  let text = try? NSAttributedString(
                    data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                    documentAttributes: nil)
            else { return "" }
            return text.string
        }
    }
}

// MARK: - Then

@MainActor
extension Then where Subject == ConsentGate {
    func showsTheSheet() -> ConsentSheet? {
        if subject.sheet == nil { fail("no \(Copy.consentSheetTitle) sheet appeared") }
        return subject.sheet
    }

    func asksNothing() {
        expect(subject.sheet == nil, "the \(Copy.consentSheetTitle) sheet appeared")
    }

    func openedNoPicker() { expect(!subject.pickerOpened, "the file picker opened before consent was recorded") }
    func openedThePicker() { expect(subject.pickerOpened, "the file picker did not open") }
}

@MainActor
extension Then where Subject == ConsentSheet {
    func asksWhoHowAndWhen() {
        expectEqual(subject.title, Copy.consentSheetTitle, "the sheet title")
        expectEqual(subject.whoOptions, Copy.consentWho, "who can consent")
        expectEqual(subject.howOptions, Copy.consentHow, "how consent was given")
        expect(abs(subject.capture.consentedAt.timeIntervalSince(subject.openedAt)) < 1, "When does not start at the moment the sheet opened")
        expectEqual(subject.capture.party, .patient, "the preselected party")
        expectEqual(subject.capture.method, .verbal, "the preselected method")
    }

    func confirmsWith(_ title: String) { expectEqual(subject.confirmTitle, title, "the confirm button") }
    func cannotConfirm() { expect(!subject.canConfirm, "\(subject.confirmTitle) is enabled before the sheet is complete") }
    func canConfirm() { expect(subject.canConfirm, "\(subject.confirmTitle) stays disabled once the sheet is complete") }
    func asksForAName() { expect(subject.asksForName, "no name is asked for") }
    func explains(_ fragment: String) { expect(subject.explanation.contains(fragment), "the explanation \"\(subject.explanation)\" does not mention \"\(fragment)\"") }
}

@MainActor
extension Then where Subject == String {
    func says(_ fragment: String) { expect(subject.contains(fragment), "\"\(subject)\" does not say \"\(fragment)\"") }
    func showsDateAndTime(of date: Date) {
        expect(subject.contains(RecordingConsent.dateTime(date)), "\"\(subject)\" does not show \(RecordingConsent.dateTime(date))")
    }
    func showsDate(of date: Date) {
        let day = date.formatted(date: .abbreviated, time: .omitted)
        expect(subject.contains(day), "\"\(subject)\" does not show \(day)")
    }
}

@MainActor
extension Then where Subject == MenuBarConsentPanel {
    func asksInPlace() {
        expect(subject.needsConsent, "the panel does not ask for consent")
        expectEqual(subject.capture.party, .patient, "the preselected party")
    }
    func cannotStart() { expect(!subject.canStart, "\(Copy.consentStartRecording) is enabled before the confirmation is ticked") }
    func canStart() { expect(subject.canStart, "\(Copy.consentStartRecording) stays disabled once ticked") }
}

@MainActor
extension Then where Subject == MenuBarStart {
    func refusedWithoutASession(_ message: String) {
        expectEqual(subject.problem, message, "the refusal")
        expect(subject.session == nil, "a session started")
        expectEqual(subject.sessionsAfter, subject.sessionsBefore, "the number of sessions")
    }
}

@MainActor
extension Then where Subject == ApplyToPatientsSheet {
    func cannotApply() { expect(!subject.canApply, "Apply is enabled with no patient selected") }
    func canApply() { expect(subject.canApply, "Apply stays disabled with patients selected") }
    func offers(_ choices: [String]) { expectEqual(subject.choices, choices, "the policy choices") }
}

@MainActor
extension Then where Subject == [AuditEvent] {
    /// One attestation for `visit` with its method, and no name anywhere.
    func attestsConsent(for visit: PatientSession, method: ConsentMethod) {
        let attested = subject.filter { $0.action == .recordingConsentAttested }
        expectEqual(attested.count, 1, "the number of consent entries")
        guard let entry = attested.first else { return }
        expectEqual(entry.actionLabel, Copy.consentAttested, "the entry's label")
        expectEqual(entry.subjectID, visit.session.id.uuidString, "the entry's session")
        let detail = entry.detail ?? ""
        expect(detail.contains(visit.patient.id.uuidString), "the entry \"\(detail)\" lacks the patient's record ID")
        expect(detail.contains(method.word), "the entry \"\(detail)\" lacks the method")
        for part in visit.patient.name.split(separator: " ") {
            expect(!detail.contains(part), "the entry names the patient: \"\(detail)\"")
        }
        expect(AuditLogCopy.recordedActions.contains(.recordingConsentAttested), "the activity log does not say it records consent")
    }
}

@MainActor
extension Then where Subject == [ConsentInExport] {
    func eachHasConsentSection(_ record: ConsentRecord) {
        for export in subject { then(export).hasConsentSection(record) }
    }

    private func then(_ export: ConsentInExport) -> Then<ConsentInExport> {
        Then<ConsentInExport>(subject: export, check: check, file: file, line: line)
    }
}

@MainActor
extension Then where Subject == ConsentInExport {
    func hasConsentSection(_ record: ConsentRecord) {
        let text = subject.text
        expect(text.contains(Copy.consentExportHeading), "the \(subject.what) export has no \"\(Copy.consentExportHeading)\" section")
        expect(text.contains(record.party.title), "the \(subject.what) export does not say who consented")
        expect(text.contains(record.method.title), "the \(subject.what) export does not say how")
        expect(text.contains(RecordingConsent.dateTime(record.consentedAt)), "the \(subject.what) export does not say when")
    }
}

@MainActor
extension Then where Subject == ConsentSaveAttempt {
    func wasRefusedAndKept() {
        guard let error = subject.error else { return fail("saving consent on a signed session was allowed") }
        if case .consentLocked? = error as? StoreError {} else { fail("refused for the wrong reason: \(error)") }
        expect(subject.recordBefore != nil, "the session had no consent to keep")
        expectEqual(subject.recordAfter, subject.recordBefore, "the consent after the refused save")
    }
}

@MainActor
extension Then where Subject == SealedConsent {
    func isSealedAndReadsBack() {
        let raw = String(decoding: subject.rawBytes, as: UTF8.self)
        expect(!raw.contains("verbal") && !raw.contains(subject.written.sessionID.uuidString),
               "consent.json is stored in the clear")
        expectEqual(subject.readBack, subject.written, "the consent read back after reopening")
    }
}
