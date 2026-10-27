import CryptoKit
import XCTest
@testable import Aletheia

/// Recording consent: the policy (Settings default, per-patient override), the
/// sheet's rules, the sealed per-session record, its activity-log entry, and
/// the lock once a note is signed.
@MainActor
final class RecordingConsentTests: XCTestCase {
    private struct NoopSpotlightIndexer: SpotlightIndexing {
        func replaceIndex(with entries: [SpotlightEntry]) {}
        func clear() {}
    }

    private final class MemoryDeviceKeys: DeviceKeyStoring {
        var storage: [String: SymmetricKey] = [:]
        func save(_ key: SymmetricKey, for id: String) throws { storage[id] = key }
        func load(for id: String) -> SymmetricKey? { storage[id] }
        func delete(for id: String) { storage[id] = nil }
    }

    private struct FixedDisk: DiskEncryptionProbing {
        func isDataVolumeEncrypted(_ url: URL) -> Bool? { true }
    }

    private var tempRoot: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private let auditKey = SymmetricKey(size: .bits256)

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        suite = "RecordingConsentTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        SessionSearch.index = SearchIndex()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeModel() -> AppModel {
        let root = tempRoot!
        let settings = AppSettings(defaults: defaults)
        settings.dataRootURL = root
        let encryption = EncryptionManager(dataRootProvider: { root }, deviceKeys: MemoryDeviceKeys(), defaults: defaults)
        let model = AppModel(settings: settings, encryption: encryption, spotlightIndexer: NoopSpotlightIndexer())
        model.diskProbe = FixedDisk()
        let key = auditKey
        model.auditKeyProvider = { key }
        model.rebuildStore()
        return model
    }

    private func complete(_ party: ConsentParty = .patient, name: String = "", method: ConsentMethod = .verbal,
                          at date: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> ConsentCapture {
        var capture = ConsentCapture(openedAt: date)
        capture.party = party
        capture.name = name
        capture.method = method
        capture.confirmed = true
        return capture
    }

    // MARK: - Policy

    func testDefaultPolicyIsFirstSession() {
        XCTAssertEqual(ConsentPolicy.default, .firstSession)
        XCTAssertEqual(makeModel().settings.recordingConsentPolicy, .firstSession)
    }

    func testSettingsPolicySurvivesRelaunch() {
        makeModel().settings.recordingConsentPolicy = .everySession
        XCTAssertEqual(AppSettings(defaults: defaults).recordingConsentPolicy, .everySession)
    }

    func testPatientPolicyOverridesTheDefault() {
        let follows = Patient(name: "A", slug: "a")
        let own = Patient(name: "B", slug: "b", recordingConsentPolicy: .everySession)
        XCTAssertEqual(RecordingConsent.effectivePolicy(for: follows, default: .firstSession), .firstSession)
        XCTAssertEqual(RecordingConsent.effectivePolicy(for: own, default: .firstSession), .everySession)
        XCTAssertEqual(RecordingConsent.effectivePolicy(for: nil, default: .everySession), .everySession)
    }

    func testFirstSessionAsksOnlyUntilThePatientHasConsented() {
        let fresh = Patient(name: "A", slug: "a")
        let consented = Patient(name: "A", slug: "a", recordingConsentAttestedAt: Date())
        XCTAssertTrue(RecordingConsent.needsCapture(patient: fresh, policy: .firstSession, sessionHasRecord: false))
        XCTAssertFalse(RecordingConsent.needsCapture(patient: consented, policy: .firstSession, sessionHasRecord: false))
        XCTAssertTrue(RecordingConsent.needsCapture(patient: consented, policy: .everySession, sessionHasRecord: false))
        XCTAssertFalse(RecordingConsent.needsCapture(patient: fresh, policy: .everySession, sessionHasRecord: true),
                       "a session with its own record never asks again")
    }

    func testPolicyChoiceMapsUseDefaultToNil() {
        XCTAssertEqual(ConsentPolicyChoice.allCases.map(\.title), ["Use default", "First session", "Every session"])
        XCTAssertNil(ConsentPolicyChoice.useDefault.policy)
        XCTAssertEqual(ConsentPolicyChoice(.everySession), .everySession)
        XCTAssertEqual(ConsentPolicyChoice(nil), .useDefault)
    }

    func testSetConsentPolicyUpdatesOnlyTheChosenPatients() throws {
        let model = makeModel()
        let jane = try XCTUnwrap(model.addPatient(name: "Jane Doe"))
        let adam = try XCTUnwrap(model.addPatient(name: "Adam Roe"))
        model.setConsentPolicy(.everySession, forPatients: [jane.id])
        XCTAssertEqual(model.consentPolicy(for: jane), .everySession)
        XCTAssertEqual(model.consentPolicy(for: adam), .firstSession)
        model.setConsentPolicy(nil, forPatients: [jane.id, adam.id])
        XCTAssertNil(model.patients.first { $0.id == jane.id }?.recordingConsentPolicy)
    }

    func testPatientPolicyRoundTripsAndOldFilesLoad() throws {
        let patient = Patient(name: "A", slug: "a", recordingConsentPolicy: .everySession)
        let back = try JSONDecoder.aletheia.decode(Patient.self, from: try JSONEncoder.aletheia.encode(patient))
        XCTAssertEqual(back.recordingConsentPolicy, .everySession)

        let old = #"{"id":"\#(UUID().uuidString)","name":"Old","notes":"","createdAt":0,"slug":"old"}"#
        let decoded = try JSONDecoder().decode(Patient.self, from: Data(old.utf8))
        XCTAssertNil(decoded.recordingConsentPolicy)
        XCTAssertNil(decoded.recordingConsentAttestedAt)
    }

    func testFolderRelocationKeepsConsentFields() {
        let patient = Patient(name: "A", slug: "stale", recordingConsentAttestedAt: Date(), recordingConsentPolicy: .everySession)
        let located = Store.locatedIn(URL(fileURLWithPath: "/tmp/Patients/fresh"), patient)
        XCTAssertEqual(located.slug, "fresh")
        XCTAssertEqual(located.recordingConsentAttestedAt, patient.recordingConsentAttestedAt)
        XCTAssertEqual(located.recordingConsentPolicy, .everySession)
    }

    // MARK: - The sheet's rules

    func testCaptureNeedsTheTickAndANameForSomeoneElse() {
        var capture = ConsentCapture()
        XCTAssertFalse(capture.isComplete)
        capture.confirmed = true
        XCTAssertTrue(capture.isComplete)
        capture.party = .guardian
        XCTAssertFalse(capture.isComplete)
        capture.name = "   "
        XCTAssertFalse(capture.isComplete)
        capture.name = "Sam Doe"
        XCTAssertTrue(capture.isComplete)
    }

    func testRecordKeepsTheNameOnlyForSomeoneElseAndNeverAFutureTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var capture = complete(.patient, name: "ignored", at: now.addingTimeInterval(3_600))
        var record = capture.record(sessionID: UUID(), patientID: UUID(), policy: .firstSession, now: now, recordedBy: "me")
        XCTAssertNil(record.consenterName)
        XCTAssertEqual(record.consentedAt, now)
        XCTAssertEqual(record.statement, RecordingConsent.attestationText)

        capture.party = .representative
        capture.name = "  Sam Doe "
        record = capture.record(sessionID: UUID(), patientID: UUID(), policy: .everySession, now: now, recordedBy: "me")
        XCTAssertEqual(record.consenterName, "Sam Doe")
        XCTAssertEqual(record.policy, .everySession)
        XCTAssertEqual(record.summary, "Consent: verbal, from a representative (Sam Doe)")
    }

    func testMenuBarRefusesUntilConsentIsComplete() {
        XCTAssertEqual(RecordingConsent.menuBarProblem(needsConsent: true, capture: ConsentCapture()),
                       RecordingConsent.notConfirmedMessage)
        XCTAssertNil(RecordingConsent.menuBarProblem(needsConsent: true, capture: complete()))
        XCTAssertNil(RecordingConsent.menuBarProblem(needsConsent: false, capture: ConsentCapture()))
    }

    func testSheetPurposeNamesTheConfirmButton() {
        XCTAssertEqual(ConsentSheetPurpose.record.confirmTitle, "Start recording")
        XCTAssertEqual(ConsentSheetPurpose.importAudio.confirmTitle, "Choose Audio File…")
        XCTAssertEqual(ConsentSheetPurpose.change.confirmTitle, "Save")
    }

    func testBulkEditNeedsAPatientAndSelectAllTicksEveryone() {
        let ids = [UUID(), UUID()]
        var edit = ConsentPolicyBulkEdit()
        XCTAssertFalse(edit.canApply)
        edit.toggle(ids[0])
        XCTAssertTrue(edit.canApply)
        XCTAssertFalse(edit.allSelected(of: ids))
        edit.selectAll(true, of: ids)
        XCTAssertTrue(edit.allSelected(of: ids))
        edit.selectAll(false, of: ids)
        XCTAssertFalse(edit.canApply)
        XCTAssertFalse(edit.allSelected(of: []))
    }

    func testProfileDraftCarriesThePolicy() {
        let patient = Patient(name: "A", slug: "a", recordingConsentPolicy: .everySession)
        var draft = PatientProfileDraft(patient: patient, showsMedications: false)
        XCTAssertEqual(draft.recordingConsent, .everySession)
        XCTAssertFalse(draft.hasChanges)
        draft.recordingConsent = .useDefault
        XCTAssertTrue(draft.hasChanges)
        var saved = patient
        draft.apply(to: &saved)
        XCTAssertNil(saved.recordingConsentPolicy)
    }

    // MARK: - The sealed record

    func testRecordConsentSealsTheRecordAndMarksThePatient() throws {
        let model = makeModel()
        let patient = try XCTUnwrap(model.addPatient(name: "Jane Doe"))
        let session = try XCTUnwrap(model.startNewSession(for: patient))
        XCTAssertTrue(model.needsRecordingConsent(patient: patient, session: session))

        let record = try model.recordConsent(complete(method: .written), patient: patient, session: session)

        XCTAssertEqual(try model.consentRecord(patient: patient, session: session), record)
        XCTAssertFalse(model.needsRecordingConsent(patient: patient, session: session))
        XCTAssertEqual(model.patients.first { $0.id == patient.id }?.recordingConsentAttestedAt, record.consentedAt)
        let second = try XCTUnwrap(model.startNewSession(for: patient))
        XCTAssertFalse(model.needsRecordingConsent(patient: patient, session: second), "first session only, by default")
        XCTAssertEqual(try model.consentStatus(patient: patient, session: second), .onFile(since: record.consentedAt))
    }

    func testIncompleteCaptureIsRefused() throws {
        let model = makeModel()
        let patient = try XCTUnwrap(model.addPatient(name: "Jane Doe"))
        let session = try XCTUnwrap(model.startNewSession(for: patient))
        XCTAssertThrowsError(try model.recordConsent(ConsentCapture(), patient: patient, session: session)) {
            XCTAssertTrue($0 is ConsentCaptureIncomplete)
        }
        XCTAssertNil(try model.consentRecord(patient: patient, session: session))
    }

    func testAttestationIsLoggedWithIDsAndMethodOnly() throws {
        let model = makeModel()
        let patient = try XCTUnwrap(model.addPatient(name: "Jane Doe"))
        let session = try XCTUnwrap(model.startNewSession(for: patient))
        try model.recordConsent(complete(.guardian, name: "Sam Doe", method: .written), patient: patient, session: session)

        let logged = try XCTUnwrap(model.audit).entries().filter { $0.action == .recordingConsentAttested }
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged.first?.subjectID, session.id.uuidString)
        let detail = try XCTUnwrap(logged.first?.detail)
        XCTAssertEqual(detail, "Patient \(patient.id.uuidString), written")
        XCTAssertFalse(detail.contains("Sam"))
        XCTAssertFalse(detail.contains("Jane"))
    }

    func testRecordIsLockedOnceANoteIsSigned() throws {
        let model = makeModel()
        let patient = try XCTUnwrap(model.addPatient(name: "Jane Doe"))
        let session = try XCTUnwrap(model.startNewSession(for: patient))
        let first = try model.recordConsent(complete(), patient: patient, session: session)
        let store = try XCTUnwrap(model.store)
        try store.saveNote("S: ok", for: patient, session: session, format: .soap)
        try store.signNote(for: patient, session: session, format: .soap)

        XCTAssertFalse(model.canChangeConsent(patient: patient, session: session))
        XCTAssertThrowsError(try model.recordConsent(complete(method: .written), patient: patient, session: session)) {
            guard case .consentLocked? = $0 as? StoreError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try model.consentRecord(patient: patient, session: session), first)
    }

    func testUnreadableRecordThrowsAndCountsAsRecorded() throws {
        let model = makeModel()
        let patient = try XCTUnwrap(model.addPatient(name: "Jane Doe"))
        let session = try XCTUnwrap(model.startNewSession(for: patient))
        let store = try XCTUnwrap(model.store)
        let url = store.sessionDir(for: patient, session: session).appendingPathComponent(Store.consentFileName)
        try Data("not json".utf8).write(to: url)

        XCTAssertThrowsError(try model.consentRecord(patient: patient, session: session))
        XCTAssertFalse(model.needsRecordingConsent(patient: patient, session: session))
        XCTAssertEqual(store.consentExportLines(for: patient, session: session), [RecordingConsent.unreadableRecord])
    }

    // MARK: - Exports

    func testExportLinesSayWhoHowAndWhen() {
        let given = Date(timeIntervalSince1970: 1_800_000_000)
        let record = complete(.guardian, name: "Sam Doe", method: .written, at: given)
            .record(sessionID: UUID(), patientID: UUID(), policy: .firstSession, now: given, recordedBy: "me")
        let lines = RecordingConsent.exportLines(.recorded(record))
        XCTAssertEqual(lines.first, "Who: Parent or guardian")
        XCTAssertTrue(lines.contains("Name: Sam Doe"))
        XCTAssertTrue(lines.contains("Method: Written"))
        XCTAssertTrue(lines.contains("Given: \(RecordingConsent.dateTime(given))"))
        XCTAssertEqual(RecordingConsent.exportLines(.none), [RecordingConsent.noConsentRecorded])
    }

    func testSessionMarkdownHasAConsentSection() throws {
        let model = makeModel()
        let patient = try XCTUnwrap(model.addPatient(name: "Jane Doe"))
        let session = try XCTUnwrap(model.startNewSession(for: patient))
        let record = try model.recordConsent(complete(), patient: patient, session: session)

        let markdown = try XCTUnwrap(model.store).exportSessionMarkdown(patient: patient, session: session)
        XCTAssertTrue(markdown.contains("## Recording consent"))
        XCTAssertTrue(markdown.contains("- Who: Patient"))
        XCTAssertTrue(markdown.contains("- Given: \(RecordingConsent.dateTime(record.consentedAt))"))
    }

    func testMarkdownLeavesTheSectionOutWithoutConsentLines() {
        let md = MarkdownExporter.session(date: Date(), patientName: "Jane Doe", transcript: "Hi.", summary: nil)
        XCTAssertFalse(md.contains("Recording consent"))
    }

    func testArchiveWritesAConsentFileForSessionsWithContent() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let sessions = [
            ArchiveSession(date: date, transcript: "Hello.", notes: [], summary: "", consent: ["Who: Patient"]),
            ArchiveSession(date: date.addingTimeInterval(86_400), transcript: "", notes: [], summary: "", consent: ["No consent recorded."]),
        ]
        let files = PatientArchive.files(patientName: "Jane Doe", background: "", sessions: sessions, exportedOn: date)
        let consent = files.filter { $0.path.hasSuffix("/Recording consent.txt") }
        XCTAssertEqual(consent.count, 1, "an empty session gets no consent file")
        XCTAssertEqual(consent.first?.text, "Recording consent\n\nWho: Patient\n")
    }
}
