import CryptoKit
import XCTest
@testable import Aletheia

/// A present-but-undecodable `session.json` / `patient.json` is corruption, not
/// "new": it must be reported, never rewritten, and never given a fresh id (that
/// would silently orphan the session's comments, notes and chat, which are
/// keyed by the id inside it). A *missing* `session.json` (a legacy or hand-made
/// folder) still gets an identity minted.
final class StoreUnreadableRecordsTests: XCTestCase {
    private var tempRoot: URL!
    private var store: Store!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreUnreadableRecordsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = Store(root: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private let garbage = Data("{ this is not valid json".utf8)

    private func sessionJSON(_ patient: Patient, _ session: SessionRecord) -> URL {
        store.sessionDir(for: patient, session: session).appendingPathComponent("session.json")
    }

    private func patientJSON(_ patient: Patient) -> URL {
        store.patientDir(for: patient).appendingPathComponent("patient.json")
    }

    // MARK: - session.json present but corrupt

    func testCorruptSessionJSONIsNotRewrittenAndYieldsTypedError() throws {
        let patient = try store.createPatient(name: "Corrupt Case")
        let session = try store.createSession(for: patient)
        let url = sessionJSON(patient, session)
        try garbage.write(to: url)
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(try store.loadSession(for: patient, folderName: session.folderName)) { error in
            guard case let StoreError.sessionMetadataUnreadable(folder, underlying) = error else {
                return XCTFail("expected sessionMetadataUnreadable, got \(error)")
            }
            XCTAssertEqual(folder.lastPathComponent, session.folderName)
            XCTAssertTrue(underlying is DecodingError)
        }

        // Listing (which used to mint a new id and overwrite the file) must not
        // touch it either, and must not list a session with an invented id.
        let listing = try store.sessionListing(for: patient)
        XCTAssertTrue(listing.sessions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), before, "the corrupt file is left byte-for-byte untouched")

        let entry = try XCTUnwrap(listing.unreadable.first)
        XCTAssertEqual(listing.unreadable.count, 1)
        XCTAssertEqual(entry.kind, .sessionRecord)
        XCTAssertEqual(entry.reason, .undecodable)
        XCTAssertEqual(entry.folder.lastPathComponent, session.folderName)
        XCTAssertEqual(entry.patientId, patient.id)
    }

    func testValidJSONMissingTheIDIsAlsoCorrupt() throws {
        let patient = try store.createPatient(name: "Empty Object")
        let session = try store.createSession(for: patient)
        let url = sessionJSON(patient, session)
        try Data("{}".utf8).write(to: url)

        XCTAssertTrue(try store.listSessions(for: patient).isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), Data("{}".utf8))
        XCTAssertEqual(store.unreadableEntries.map(\.reason), [.undecodable])
    }

    func testUnreadableSessionJSONThatIsNotAFileIsReportedNotReplaced() throws {
        let patient = try store.createPatient(name: "Not A File")
        let session = try store.createSession(for: patient)
        let url = sessionJSON(patient, session)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let listing = try store.sessionListing(for: patient)
        XCTAssertTrue(listing.sessions.isEmpty)
        XCTAssertEqual(listing.unreadable.map(\.reason), [.notReadable])
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, "whatever is at session.json is left exactly as found")
    }

    func testHealthyNeighboursStillListBesideACorruptSession() throws {
        let patient = try store.createPatient(name: "Neighbours")
        let calendar = Calendar(identifier: .gregorian)
        let healthy = try store.createSession(for: patient, on: calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!)
        let damaged = try store.createSession(for: patient, on: calendar.date(from: DateComponents(year: 2026, month: 2, day: 1))!)
        let alsoHealthy = try store.createSession(for: patient, on: calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!)
        try garbage.write(to: sessionJSON(patient, damaged))

        let listed = try store.listSessions(for: patient)
        XCTAssertEqual(listed.map(\.id), [alsoHealthy.id, healthy.id], "healthy sessions keep listing, newest first")
        XCTAssertEqual(store.unreadableEntries.count, 1, "the damaged one is recorded, not silently dropped")
    }

    /// The point of failing loud: annotations stay attached to the original id,
    /// so restoring the file (e.g. from Time Machine) brings the session back
    /// with its note and comments, none of it orphaned.
    func testRestoringTheFileReattachesTheSessionToItsAnnotations() throws {
        let patient = try store.createPatient(name: "Restore Me")
        let session = try store.createSession(for: patient)
        let comments = try XCTUnwrap(CommentStore(root: tempRoot))
        comments.saveNote(sessionID: session.id, text: "kept note")

        let url = sessionJSON(patient, session)
        let original = try Data(contentsOf: url)
        try garbage.write(to: url)
        XCTAssertTrue(try store.listSessions(for: patient).isEmpty)
        XCTAssertEqual(store.unreadableEntries.count, 1)

        try original.write(to: url)
        let relisted = try XCTUnwrap(try store.listSessions(for: patient).first)
        XCTAssertEqual(relisted.id, session.id)
        XCTAssertEqual(comments.note(sessionID: relisted.id), "kept note")
        XCTAssertTrue(store.unreadableEntries.isEmpty, "the entry clears once the file reads again")
    }

    // MARK: - session.json missing (legacy / hand-made) keeps working

    func testMissingSessionJSONStillGetsAnIdentityBesideACorruptOne() throws {
        let patient = try store.createPatient(name: "Mixed")
        let fm = FileManager.default
        let legacy = store.patientDir(for: patient).appendingPathComponent("2026-05-01_Session", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        let damaged = try store.createSession(for: patient)
        try garbage.write(to: sessionJSON(patient, damaged))

        let listing = try store.sessionListing(for: patient)
        XCTAssertEqual(listing.sessions.map(\.folderName), ["2026-05-01_Session"])
        XCTAssertEqual(listing.unreadable.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("session.json").path),
                      "the legacy folder is minted an identity as before")

        // And loadSession agrees, with a stable id.
        let first = try store.loadSession(for: patient, folderName: "2026-05-01_Session")
        let second = try store.loadSession(for: patient, folderName: "2026-05-01_Session")
        XCTAssertEqual(first.id, second.id)
    }

    func testLoadSessionForAnUnknownFolderIsSessionNotFound() throws {
        let patient = try store.createPatient(name: "Nobody Home")
        XCTAssertThrowsError(try store.loadSession(for: patient, folderName: "nope")) { error in
            guard case StoreError.sessionNotFound = error else { return XCTFail("got \(error)") }
        }
    }

    // MARK: - patient.json

    func testCorruptPatientJSONIsReportedNotSkippedOrRewritten() throws {
        let healthy = try store.createPatient(name: "Amir Healthy")
        let damaged = try store.createPatient(name: "Zoe Damaged")
        let url = patientJSON(damaged)
        try garbage.write(to: url)

        let listing = try store.patientListing()
        XCTAssertEqual(listing.patients.map(\.id), [healthy.id], "healthy patients still list")
        let entry = try XCTUnwrap(listing.unreadable.first)
        XCTAssertEqual(listing.unreadable.count, 1)
        XCTAssertEqual(entry.kind, .patientRecord)
        XCTAssertEqual(entry.reason, .undecodable)
        XCTAssertEqual(entry.folder.lastPathComponent, damaged.slug)
        XCTAssertNil(entry.patientId)
        XCTAssertEqual(try Data(contentsOf: url), garbage, "never rewritten")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.patientDir(for: damaged).path), "never deleted")

        // The plain listPatients() keeps working and the damage is on the store.
        XCTAssertEqual(try store.listPatients().map(\.id), [healthy.id])
        XCTAssertEqual(store.unreadableEntries.map(\.id), listing.unreadable.map(\.id))
    }

    func testFolderWithoutPatientJSONIsNotReported() throws {
        // A stray folder (or .DS_Store) with no patient.json isn't a patient
        // record at all, so it isn't "damaged".
        let strayDir = tempRoot.appendingPathComponent("Patients/Stray", isDirectory: true)
        try FileManager.default.createDirectory(at: strayDir, withIntermediateDirectories: true)
        try Data().write(to: tempRoot.appendingPathComponent("Patients/.DS_Store"))

        let listing = try store.patientListing()
        XCTAssertTrue(listing.patients.isEmpty)
        XCTAssertTrue(listing.unreadable.isEmpty)
    }

    func testPatientEntryClearsOnceTheFileReadsAgain() throws {
        let patient = try store.createPatient(name: "Fixable")
        let url = patientJSON(patient)
        let original = try Data(contentsOf: url)
        try garbage.write(to: url)
        XCTAssertEqual(try store.patientListing().unreadable.count, 1)

        try original.write(to: url)
        let listing = try store.patientListing()
        XCTAssertEqual(listing.patients.map(\.id), [patient.id])
        XCTAssertTrue(listing.unreadable.isEmpty)
        XCTAssertTrue(store.unreadableEntries.isEmpty)
    }

    // MARK: - Doctor-facing scan

    func testScanFindsPatientAndSessionDamageAcrossAllPatients() throws {
        let a = try store.createPatient(name: "Alpha")
        let b = try store.createPatient(name: "Bravo")
        let broken = try store.createPatient(name: "Charlie")
        _ = try store.createSession(for: a)
        let bDamaged = try store.createSession(for: b)
        try garbage.write(to: sessionJSON(b, bDamaged))
        try garbage.write(to: patientJSON(broken))

        // Nothing has listed sessions yet, so only a scan can know about them.
        XCTAssertTrue(store.unreadableEntries.isEmpty)

        let found = store.scanForUnreadableEntries()
        XCTAssertEqual(Set(found.map(\.kind)), [.patientRecord, .sessionRecord])
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(store.unreadableEntries.map(\.id), found.map(\.id))
    }

    // MARK: - Messages carry no PHI

    func testMessagesDoNotContainPatientNamesOrPaths() throws {
        let patient = try store.createPatient(name: "Zelda Quixote")
        let session = try store.createSession(for: patient)
        try garbage.write(to: sessionJSON(patient, session))
        try garbage.write(to: patientJSON(patient))

        var texts = store.scanForUnreadableEntries().map(\.message)
        do {
            _ = try store.loadSession(for: patient, folderName: session.folderName)
            XCTFail("expected an error")
        } catch {
            texts.append(error.localizedDescription)
        }
        XCTAssertFalse(texts.isEmpty)
        for text in texts {
            XCTAssertFalse(text.contains("Zelda"), text)
            XCTAssertFalse(text.contains("Quixote"), text)
            XCTAssertFalse(text.contains(tempRoot.path), text)
        }
    }

    // MARK: - Locked folders are not "damaged"

    func testSealedPatientReadWithoutAKeyIsNotReportedAsDamaged() throws {
        let keyed = FileProtector(key: SymmetricKey(size: .bits256))
        _ = try Store(root: tempRoot, protector: keyed).createPatient(name: "Sealed Sam")

        // A passthrough store models the folder while locked: it can't open the
        // envelope, but that's a lock, which the app handles separately.
        let locked = Store(root: tempRoot, protector: .passthrough)
        let listing = try locked.patientListing()
        XCTAssertTrue(listing.patients.isEmpty)
        XCTAssertTrue(listing.unreadable.isEmpty)
    }
}
