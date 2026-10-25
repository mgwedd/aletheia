import CryptoKit
import XCTest
@testable import Aletheia

final class AllRecordsExportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AllRecordsExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static func date(_ day: Int, _ hour: Int = 9) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: 30))!
    }

    /// Patients and sessions held in memory; recordings are real files under `audioDir`.
    private final class FakeSource: AllRecordsSource {
        var patients: [AllRecordsPatient]
        var sessions: [[ArchiveSession]]
        var audio: [String: [AllRecordsRecording]] = [:]
        var unreadablePatientCount = 0
        var unreadableSessionCount = 0
        var failOn: (Int, Int)?
        var temporaryCopies: [URL] = []
        var readsDecryptToTemporary = false

        init(_ patients: [(String, [ArchiveSession])]) {
            self.patients = patients.map { AllRecordsPatient(name: $0.0, background: "", sessionCount: $0.1.count) }
            self.sessions = patients.map(\.1)
        }

        func loadSession(patient: Int, session: Int) throws -> ArchiveSession {
            if let failOn, failOn == (patient, session) { throw CocoaError(.fileReadCorruptFile) }
            return sessions[patient][session]
        }

        func recordings(patient: Int, session: Int) -> [AllRecordsRecording] {
            audio["\(patient)/\(session)"] ?? []
        }

        func readableRecording(at url: URL) throws -> (url: URL, isTemporary: Bool) {
            guard readsDecryptToTemporary else { return (url, false) }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("arx-\(UUID().uuidString).caf")
            try FileManager.default.copyItem(at: url, to: temp)
            temporaryCopies.append(temp)
            return (temp, true)
        }
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func makeAudio(_ name: String, bytes: Int = 64) throws -> URL {
        let url = root.appendingPathComponent("src-\(name)")
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    // MARK: - Writing

    func testEveryPatientGetsAFolderWithTextAndRecordings() throws {
        let source = FakeSource([
            ("Jane Doe", [ArchiveSession(date: Self.date(2), transcript: "Hello.", notes: [], summary: "", comments: []),
                          ArchiveSession(date: Self.date(1), transcript: "", notes: [], summary: "", comments: [])]),
            ("Sam Roe", [ArchiveSession(date: Self.date(5), transcript: "Hi.", notes: [ArchiveNote(formatName: "SOAP", text: "S: ok")], summary: "", comments: [])]),
        ])
        // The audio-only session (index 1, the older one) still gets its recording.
        source.audio["0/1"] = [AllRecordsRecording(name: AllRecordsExport.micRecordingName, url: try makeAudio("mic", bytes: 100))]
        source.audio["1/0"] = [AllRecordsRecording(name: AllRecordsExport.callRecordingName, url: try makeAudio("call"))]
        let destination = root.appendingPathComponent("Aletheia records")

        let outcome = try AllRecordsExport.write(from: source, to: destination, progress: { _, _ in }, isCancelled: { false })

        let jane = destination.appendingPathComponent("Jane Doe records/Sessions")
        XCTAssertEqual(try text(jane.appendingPathComponent("2026-03-02 09.30/Transcript.txt")), "Hello.\n")
        XCTAssertEqual(try Data(contentsOf: jane.appendingPathComponent("2026-03-01 09.30/\(AllRecordsExport.micRecordingName)")).count, 100)
        let sam = destination.appendingPathComponent("Sam Roe records/Sessions/2026-03-05 09.30")
        XCTAssertEqual(try text(sam.appendingPathComponent("Note - SOAP.txt")), "S: ok\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sam.appendingPathComponent(AllRecordsExport.callRecordingName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Jane Doe records/Read me.txt").path))

        let readMe = try text(destination.appendingPathComponent("Read me.txt"))
        XCTAssertTrue(readMe.contains("Patients: 2"))
        XCTAssertTrue(readMe.contains("Sessions: 3"))
        XCTAssertTrue(readMe.contains("Recordings: 2"))
        XCTAssertTrue(readMe.contains("not encrypted"))

        XCTAssertEqual(outcome.patientCount, 2)
        XCTAssertEqual(outcome.sessionCount, 3)
        // Jane: Read me + transcript; Sam: Read me + transcript + note; 2 recordings; top Read me.
        XCTAssertEqual(outcome.fileCount, 8)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains(".partial-") }
        XCTAssertEqual(leftovers, [])
    }

    func testPatientsWithTheSameNameGetSeparateFolders() throws {
        let one = ArchiveSession(date: Self.date(1), transcript: "First.", notes: [], summary: "", comments: [])
        let two = ArchiveSession(date: Self.date(1), transcript: "Second.", notes: [], summary: "", comments: [])
        let source = FakeSource([("Jane Doe", [one]), ("jane doe", [two]), ("", [])])
        let destination = root.appendingPathComponent("out")
        _ = try AllRecordsExport.write(from: source, to: destination, progress: { _, _ in }, isCancelled: { false })

        XCTAssertEqual(try text(destination.appendingPathComponent("Jane Doe records/Sessions/2026-03-01 09.30/Transcript.txt")), "First.\n")
        XCTAssertEqual(try text(destination.appendingPathComponent("jane doe records (2)/Sessions/2026-03-01 09.30/Transcript.txt")), "Second.\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Patient records/Read me.txt").path))
    }

    func testADecryptedTemporaryCopyIsMovedNotLeftBehind() throws {
        let source = FakeSource([("Jane", [ArchiveSession(date: Self.date(1), transcript: "x", notes: [], summary: "", comments: [])])])
        let original = try makeAudio("mic")
        source.audio["0/0"] = [AllRecordsRecording(name: AllRecordsExport.micRecordingName, url: original)]
        source.readsDecryptToTemporary = true
        let destination = root.appendingPathComponent("out")
        _ = try AllRecordsExport.write(from: source, to: destination, progress: { _, _ in }, isCancelled: { false })

        XCTAssertEqual(source.temporaryCopies.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.temporaryCopies[0].path), "the decrypted temp copy is moved into the export")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "the original recording is untouched")
    }

    @MainActor
    func testASyncedFolderIsRefusedAndNothingIsWritten() throws {
        let synced = root.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: synced, withIntermediateDirectories: true)
        let source = FakeSource([("Jane", [ArchiveSession(date: Self.date(1), transcript: "x", notes: [], summary: "", comments: [])])])
        XCTAssertThrowsError(try AllRecordsExport.write(
            from: source, to: synced.appendingPathComponent("out"), progress: { _, _ in }, isCancelled: { false })
        ) { XCTAssertEqual($0 as? AllRecordsExport.SyncedFolderRefusal, AllRecordsExport.SyncedFolderRefusal()) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: synced.path), [])
        XCTAssertTrue(ExportJobCenter.message(for: AllRecordsExport.SyncedFolderRefusal()).contains("Nothing was exported"))
    }

    func testAFailureRemovesThePartialFolder() throws {
        let sample = ArchiveSession(date: Self.date(1), transcript: "x", notes: [], summary: "", comments: [])
        let source = FakeSource([("A", [sample]), ("B", [sample, sample])])
        source.failOn = (1, 1)
        let destination = root.appendingPathComponent("out")
        XCTAssertThrowsError(try AllRecordsExport.write(from: source, to: destination, progress: { _, _ in }, isCancelled: { false }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [], "nothing left behind, including patient A's files")
    }

    func testCancellingRemovesThePartialFolder() throws {
        let sample = ArchiveSession(date: Self.date(1), transcript: "x", notes: [], summary: "", comments: [])
        let source = FakeSource([("A", [sample, sample, sample])])
        var reads = 0
        let destination = root.appendingPathComponent("out")
        XCTAssertThrowsError(try AllRecordsExport.write(
            from: source, to: destination, progress: { _, _ in reads += 1 }, isCancelled: { reads > 2 }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testProgressCountsPatientsAndSessionsAndNeverGoesBack() throws {
        let sample = ArchiveSession(date: Self.date(1), transcript: "x", notes: [], summary: "", comments: [])
        let source = FakeSource([("A", [sample]), ("B", [sample, sample])])
        var updates: [(Double, String)] = []
        _ = try AllRecordsExport.write(
            from: source, to: root.appendingPathComponent("out"), progress: { updates.append(($0, $1)) }, isCancelled: { false }
        )
        XCTAssertEqual(updates.map(\.1).prefix(3), [
            "Patient 1 of 2 · session 1 of 1", "Patient 2 of 2 · session 1 of 2", "Patient 2 of 2 · session 2 of 2",
        ])
        XCTAssertEqual(updates.last?.0, 1)
        XCTAssertEqual(updates.map(\.0), updates.map(\.0).sorted())
    }

    func testUnreadablePatientsAreCountedInTheReadMe() throws {
        let source = FakeSource([])
        source.unreadablePatientCount = 2
        let destination = root.appendingPathComponent("out")
        _ = try AllRecordsExport.write(from: source, to: destination, progress: { _, _ in }, isCancelled: { false })
        XCTAssertTrue(try text(destination.appendingPathComponent("Read me.txt"))
            .contains("Patient records that couldn't be read and are not included: 2"))
    }

    func testUnreadableSessionsAreCountedInTheReadMe() throws {
        let source = FakeSource([])
        source.unreadableSessionCount = 3
        let destination = root.appendingPathComponent("out")
        _ = try AllRecordsExport.write(from: source, to: destination, progress: { _, _ in }, isCancelled: { false })
        XCTAssertTrue(try text(destination.appendingPathComponent("Read me.txt"))
            .contains("Session records that couldn't be read and are not included: 3"))
    }

    func testAnAudioOnlySessionIsNotReportedAsLeftOut() throws {
        let source = FakeSource([("Jane", [ArchiveSession(date: Self.date(1), transcript: "", notes: [], summary: "", comments: [])])])
        source.audio["0/0"] = [AllRecordsRecording(name: AllRecordsExport.micRecordingName, url: try makeAudio("mic"))]
        let destination = root.appendingPathComponent("out")
        _ = try AllRecordsExport.write(from: source, to: destination, progress: { _, _ in }, isCancelled: { false })
        let readMe = try text(destination.appendingPathComponent("Jane records/Read me.txt"))
        XCTAssertTrue(readMe.contains("Sessions in this export: 1"), readMe)
        XCTAssertFalse(readMe.contains("left out"), readMe)
    }

    func testALockedStoreRefusesToExportInsteadOfExportingNothing() throws {
        let store = Store(root: root.appendingPathComponent("data"), protector: .locked)
        XCTAssertThrowsError(try StoreAllRecordsSource(store: store)) {
            XCTAssertEqual($0 as? FileProtector.ProtectorError, .locked)
        }
    }

    func testTheFolderNameIsDatedAndUnique() {
        let day = Self.date(4)
        XCTAssertEqual(AllRecordsExport.folderName(exportedOn: day, existing: []), "Aletheia records 2026-03-04")
        XCTAssertEqual(AllRecordsExport.folderName(exportedOn: day, existing: ["aletheia records 2026-03-04"]),
                       "Aletheia records 2026-03-04 (2)")
    }

    // MARK: - From a real store

    func testASealedRecordingIsExportedDecrypted() throws {
        let protector = FileProtector(key: SymmetricKey(size: .bits256))
        let store = Store(root: root.appendingPathComponent("data"), protector: protector)
        let patient = try store.createPatient(name: "Alex Doe")
        let session = try store.createSession(for: patient, on: Self.date(3))
        try store.saveTranscript("[00:00] Therapist: Hello.", for: patient, session: session)
        let audio = Data((0..<200_000).map { UInt8($0 % 251) })
        let mic = store.micRecordingURL(for: patient, session: session)
        try FileManager.default.createDirectory(at: mic.deletingLastPathComponent(), withIntermediateDirectories: true)
        try audio.write(to: mic)
        try protector.sealLargeFileInPlace(at: mic)
        XCTAssertNotEqual(try Data(contentsOf: mic), audio, "sealed at rest")

        let source = try StoreAllRecordsSource(store: store)
        let destination = root.appendingPathComponent("out")
        let outcome = try AllRecordsExport.write(from: source, to: destination, progress: { _, _ in }, isCancelled: { false })

        let sessionFolder = destination.appendingPathComponent("Alex Doe records/Sessions/2026-03-03 09.30")
        XCTAssertEqual(try Data(contentsOf: sessionFolder.appendingPathComponent(AllRecordsExport.micRecordingName)), audio)
        XCTAssertTrue(try text(sessionFolder.appendingPathComponent("Transcript.txt")).contains("Hello."))
        XCTAssertEqual(outcome.patientCount, 1)
        XCTAssertNotEqual(try Data(contentsOf: mic), audio, "the stored recording stays sealed")
    }

    // MARK: - Destination check

    func testAnEncryptedLocalFolderNeedsNoWarning() {
        XCTAssertEqual(ExportDestinationCheck.warnings(volumeEncrypted: true, isSynced: false), [])
    }

    func testAnUnencryptedOrUnknownDiskWarns() {
        XCTAssertEqual(ExportDestinationCheck.warnings(volumeEncrypted: false, isSynced: false), [ExportDestinationCheck.unencrypted])
        XCTAssertEqual(ExportDestinationCheck.warnings(volumeEncrypted: nil, isSynced: false), [ExportDestinationCheck.unknown])
    }

    func testASyncedFolderWarnsFirst() {
        XCTAssertEqual(ExportDestinationCheck.warnings(volumeEncrypted: false, isSynced: true),
                       [ExportDestinationCheck.synced, ExportDestinationCheck.unencrypted])
        XCTAssertEqual(ExportDestinationCheck.warnings(volumeEncrypted: true, isSynced: true), [ExportDestinationCheck.synced])
    }

    func testCloudFoldersAreRecognisedByPath() {
        let home = "/Users/someone"
        XCTAssertTrue(ExportDestinationCheck.pathLooksSynced(URL(fileURLWithPath: "\(home)/Library/Mobile Documents/com~apple~CloudDocs/Exports")))
        XCTAssertTrue(ExportDestinationCheck.pathLooksSynced(URL(fileURLWithPath: "\(home)/Library/CloudStorage/Dropbox/x")))
        XCTAssertFalse(ExportDestinationCheck.pathLooksSynced(URL(fileURLWithPath: "\(home)/Documents/Exports")))
        XCTAssertFalse(ExportDestinationCheck.pathLooksSynced(URL(fileURLWithPath: "/Volumes/Backup/Exports")))
    }

    func testTheInspectorCombinesTheDiskAndSyncReads() {
        struct Probe: DiskEncryptionProbing {
            let value: Bool?
            func isDataVolumeEncrypted(_ url: URL) -> Bool? { value }
        }
        let folder = URL(fileURLWithPath: "/Volumes/Backup/Exports")
        XCTAssertEqual(ExportDestinationInspector(encryption: Probe(value: true), isUbiquitous: { _ in false }).warnings(for: folder), [])
        XCTAssertEqual(ExportDestinationInspector(encryption: Probe(value: true), isUbiquitous: { _ in true }).warnings(for: folder),
                       [ExportDestinationCheck.synced])
        XCTAssertEqual(ExportDestinationInspector(encryption: Probe(value: false), isUbiquitous: { _ in false }).warnings(for: folder),
                       [ExportDestinationCheck.unencrypted])
    }

    func testTheToastSummaryNamesAFolderForAllRecords() {
        XCTAssertEqual(ExportStatusToast.summary(.init(sessionCount: 3, fileCount: 7, byteCount: 1, patientCount: 2)),
                       "2 patients, 3 sessions, 7 files in a folder.")
        XCTAssertEqual(ExportStatusToast.summary(.init(sessionCount: 1, fileCount: 2, byteCount: 1)),
                       "1 session, 2 files in a zip of text files.")
    }
}
