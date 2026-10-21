import Compression
import XCTest
@testable import Aletheia

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9, _ minute: Int = 30) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func session(
    _ date: Date, transcript: String = "", notes: [ArchiveNote] = [], summary: String = "", comments: [ArchiveComment] = []
) -> ArchiveSession {
    ArchiveSession(date: date, transcript: transcript, notes: notes, summary: summary, comments: comments)
}

/// A reader for what `ZipArchive` writes, independent of the writer: it follows the
/// end-of-directory record to the central directory, then to each local header.
private struct ZipContents {
    struct Item {
        let name: String
        let method: Int
        let data: Data
    }

    let items: [Item]

    init(_ archive: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let zip = Data(archive)
        func u16(_ offset: Int) -> Int { Int(zip[offset]) | Int(zip[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }

        var end = zip.count - 22
        while end >= 0, u32(end) != 0x0605_4B50 { end -= 1 }
        XCTAssertGreaterThanOrEqual(end, 0, "no end-of-directory record", file: file, line: line)
        let count = u16(end + 10)
        XCTAssertEqual(count, u16(end + 8), file: file, line: line)
        let directorySize = u32(end + 12)
        let directoryOffset = u32(end + 16)
        XCTAssertEqual(directoryOffset + directorySize, end, file: file, line: line)

        var items: [Item] = []
        var cursor = directoryOffset
        for _ in 0..<count {
            XCTAssertEqual(u32(cursor), 0x0201_4B50, file: file, line: line)
            XCTAssertEqual(u16(cursor + 8) & 0x0800, 0x0800, "names are flagged UTF-8", file: file, line: line)
            let method = u16(cursor + 10)
            let crc = u32(cursor + 16)
            let compressedSize = u32(cursor + 20)
            let size = u32(cursor + 24)
            let nameLength = u16(cursor + 28)
            let extraLength = u16(cursor + 30)
            let commentLength = u16(cursor + 32)
            let local = u32(cursor + 42)
            let name = String(decoding: zip[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)

            XCTAssertEqual(u32(local), 0x0403_4B50, file: file, line: line)
            XCTAssertEqual(u32(local + 14), crc, "local and central CRC agree", file: file, line: line)
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            let payload = Data(zip[start..<(start + compressedSize)])
            var data = payload
            if method == 8 {
                var out = [UInt8](repeating: 0, count: size)
                let written = payload.withUnsafeBytes { source -> Int in
                    guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(&out, size, base, payload.count, nil, COMPRESSION_ZLIB)
                }
                XCTAssertEqual(written, size, file: file, line: line)
                data = Data(out)
            } else {
                XCTAssertEqual(method, 0, file: file, line: line)
                XCTAssertEqual(compressedSize, size, file: file, line: line)
            }
            XCTAssertEqual(Int(ZipArchive.crc32(data)), crc, "CRC of \(name)", file: file, line: line)
            items.append(Item(name: name, method: method, data: data))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        self.items = items
    }

    func text(_ name: String) -> String? {
        items.first { $0.name == name }.map { String(decoding: $0.data, as: UTF8.self) }
    }
}

final class ZipArchiveTests: XCTestCase {
    private let stamp = date(2026, 9, 16)

    private func entry(_ path: String, _ text: String) -> ZipArchive.Entry {
        ZipArchive.Entry(path: path, data: Data(text.utf8), modified: stamp)
    }

    func testCRC32MatchesTheStandardCheckValue() {
        XCTAssertEqual(ZipArchive.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(ZipArchive.crc32(Data()), 0)
    }

    func testEntriesRoundTripThroughAnIndependentReader() throws {
        let long = String(repeating: "She talked about sleep and work. ", count: 400)
        let zip = try ZipArchive.data(for: [
            entry("A/Transcript.txt", long),
            entry("A/Note - SOAP.txt", "Short."),
            entry("Read me.txt", ""),
        ])
        let contents = try ZipContents(zip)
        XCTAssertEqual(contents.items.map(\.name), ["A/Transcript.txt", "A/Note - SOAP.txt", "Read me.txt"])
        XCTAssertEqual(contents.text("A/Transcript.txt"), long)
        XCTAssertEqual(contents.text("A/Note - SOAP.txt"), "Short.")
        XCTAssertEqual(contents.text("Read me.txt"), "")
    }

    func testRepetitiveTextIsDeflatedAndTinyOrEmptyTextIsStored() throws {
        let long = String(repeating: "sleep and work ", count: 500)
        let contents = try ZipContents(ZipArchive.data(for: [
            entry("long.txt", long), entry("tiny.txt", "ok"), entry("empty.txt", ""),
        ]))
        XCTAssertEqual(contents.items.first { $0.name == "long.txt" }?.method, 8)
        XCTAssertEqual(contents.items.first { $0.name == "tiny.txt" }?.method, 0)
        XCTAssertEqual(contents.items.first { $0.name == "empty.txt" }?.method, 0)
        let zip = try ZipArchive.data(for: [entry("long.txt", long)])
        XCTAssertLessThan(zip.count, long.utf8.count / 4)
    }

    func testNonASCIINamesAndTextSurvive() throws {
        let zip = try ZipArchive.data(for: [entry("José Núñez records/Notes.txt", "Café, naïve, 日本語")])
        let contents = try ZipContents(zip)
        XCTAssertEqual(contents.text("José Núñez records/Notes.txt"), "Café, naïve, 日本語")
    }

    func testBadPathsAreRefused() {
        for path in ["", "/abs.txt", "../up.txt", "a/../b.txt", "a//b.txt", "a\\b.txt", "./a.txt", String(repeating: "x", count: 256)] {
            XCTAssertFalse(ZipArchive.isValid(path: path), path)
            XCTAssertThrowsError(try ZipArchive.data(for: [entry(path, "x")]), path) { error in
                XCTAssertEqual(error as? ZipArchive.Failure, .invalidPath(path))
            }
        }
        XCTAssertTrue(ZipArchive.isValid(path: "Jane records/Sessions/2026-09-16 09.30/Transcript.txt"))
    }

    func testMoreEntriesThanTheFormatHoldsIsRefused() {
        let entries = (0...ZipArchive.maxEntries).map { _ in entry("a", "") }
        XCTAssertThrowsError(try ZipArchive.data(for: entries)) { error in
            XCTAssertEqual(error as? ZipArchive.Failure, .tooManyEntries)
        }
    }

    func testAnEmptyArchiveIsJustTheEndRecord() throws {
        let zip = try ZipArchive.data(for: [])
        XCTAssertEqual(zip.count, 22)
        XCTAssertTrue(try ZipContents(zip).items.isEmpty)
    }

    /// The reader above is mine, so also ask the system's own unzip.
    func testSystemUnzipAcceptsTheArchiveAndReadsBackTheText() throws {
        let unzip = "/usr/bin/unzip"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: unzip))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let long = String(repeating: "Notes about sleep. ", count: 300)
        let file = folder.appendingPathComponent("test.zip")
        try ZipArchive.data(for: [entry("Jane records/Sessions/one/Transcript.txt", long), entry("Jane records/Read me.txt", "Hi\n")])
            .write(to: file)

        func run(_ arguments: [String]) throws -> (status: Int32, output: Data) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: unzip)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do { try process.run() } catch { throw XCTSkip("can't launch unzip here: \(error)") }
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, output)
        }
        XCTAssertEqual(try run(["-t", file.path]).status, 0)
        let printed = try run(["-p", file.path, "Jane records/Sessions/one/Transcript.txt"])
        XCTAssertEqual(printed.status, 0)
        XCTAssertEqual(String(decoding: printed.output, as: UTF8.self), long)
    }
}

final class PatientArchiveTests: XCTestCase {
    private let exported = date(2026, 10, 21)

    private func files(
        name: String = "Jane Doe", background: String = "", _ sessions: [ArchiveSession]
    ) -> [ArchiveFile] {
        PatientArchive.files(patientName: name, background: background, sessions: sessions, exportedOn: exported)
    }

    func testSessionsAreFoldersOldestFirstWithTheirFiles() {
        let result = files([
            session(date(2026, 3, 5, 14, 0), transcript: "March talk.", notes: [ArchiveNote(formatName: "SOAP", text: "S: March.")]),
            session(date(2026, 1, 5), transcript: "January talk."),
        ])
        XCTAssertEqual(result.map(\.path), [
            "Jane Doe records/Read me.txt",
            "Jane Doe records/Sessions/2026-01-05 09.30/Transcript.txt",
            "Jane Doe records/Sessions/2026-03-05 14.00/Transcript.txt",
            "Jane Doe records/Sessions/2026-03-05 14.00/Note - SOAP.txt",
        ])
        XCTAssertEqual(result[1].text, "January talk.\n")
    }

    func testPatientNotesComeBeforeTheSessionsWhenPresent() {
        let result = files(background: "  Prefers mornings.  ", [session(date(2026, 1, 5), transcript: "x")])
        XCTAssertEqual(Array(result.map(\.path).prefix(2)), ["Jane Doe records/Read me.txt", "Jane Doe records/Patient notes.txt"])
        XCTAssertEqual(result[1].text, "Prefers mornings.\n")
        XCTAssertFalse(files([session(date(2026, 1, 5), transcript: "x")]).contains { $0.path.hasSuffix("Patient notes.txt") })
    }

    func testEachFormatKeepsItsOwnNoteAndTheLatestSummaryOnlyFillsAGap() {
        let withNotes = files([session(
            date(2026, 1, 5),
            notes: [ArchiveNote(formatName: "SOAP", text: "soap"), ArchiveNote(formatName: "Summary", text: "plain")],
            summary: "plain"
        )])
        XCTAssertEqual(
            withNotes.map { ($0.path as NSString).lastPathComponent }.filter { $0.hasPrefix("Note") || $0 == "Summary.txt" },
            ["Note - SOAP.txt", "Note - Summary.txt"]
        )
        let legacy = files([session(date(2026, 1, 5), summary: "An older summary.")])
        XCTAssertTrue(legacy.contains { $0.path.hasSuffix("/Summary.txt") && $0.text == "An older summary.\n" })
    }

    func testCommentsReadAsPlainText() throws {
        let text = try XCTUnwrap(PatientArchive.commentsText([
            ArchiveComment(anchorSeconds: 754, quotedText: "I can't sleep", body: "Ask about caffeine.", resolved: false),
            ArchiveComment(anchorSeconds: nil, quotedText: "", body: "General note.", resolved: true),
        ]))
        XCTAssertEqual(text, "[12:34] \u{201C}I can't sleep\u{201D}\nAsk about caffeine.\n\nGeneral note.\n(Resolved)\n")
        XCTAssertNil(PatientArchive.commentsText([]))
    }

    func testSessionsWithNothingAreLeftOutAndCounted() throws {
        let result = files([
            session(date(2026, 1, 5), transcript: "Talk."),
            session(date(2026, 2, 5)),
            session(date(2026, 3, 5), transcript: "  \n "),
        ])
        XCTAssertEqual(result.filter { $0.path.contains("/Sessions/") }.count, 1)
        let readMe = try XCTUnwrap(result.first { $0.path.hasSuffix("Read me.txt") }).text
        XCTAssertTrue(readMe.contains("Sessions in this export: 1"))
        XCTAssertTrue(readMe.contains("left out): 2"))
        XCTAssertTrue(readMe.contains("Jane Doe: records"))
    }

    func testTwoSessionsInTheSameMinuteGetDistinctFolders() {
        let moment = date(2026, 1, 5)
        let result = files([session(moment, transcript: "a"), session(moment, transcript: "b")])
        let folders = result.filter { $0.path.hasSuffix("Transcript.txt") }.map(\.path)
        XCTAssertEqual(folders, [
            "Jane Doe records/Sessions/2026-01-05 09.30/Transcript.txt",
            "Jane Doe records/Sessions/2026-01-05 09.30 (2)/Transcript.txt",
        ])
        XCTAssertEqual(result.filter { $0.path.hasSuffix("Transcript.txt") }.map(\.text), ["a\n", "b\n"])
    }

    func testNamesAreSafeAsPathComponents() {
        XCTAssertEqual(PatientArchive.fileSafe("Jane/Doe: Jr."), "Jane-Doe- Jr.")
        XCTAssertEqual(PatientArchive.fileSafe("..hidden"), "hidden")
        XCTAssertEqual(PatientArchive.fileSafe("  "), "Untitled")
        XCTAssertEqual(PatientArchive.fileSafe(String(repeating: "x", count: 200)).count, 80)
        let result = files(name: "../../etc/passwd", [session(date(2026, 1, 5), transcript: "x")])
        XCTAssertTrue(result.allSatisfy { ZipArchive.isValid(path: $0.path) }, "\(result.map(\.path))")
        XCTAssertEqual(files(name: "", [session(date(2026, 1, 5), transcript: "x")]).first?.path, "Patient records/Read me.txt")
    }

    func testNotesBecomePlainTextWithoutMarkdownSymbols() {
        let plain = PatientArchive.plainText(fromMarkdown: "## Plan\n\nContinue **weekly** sessions.\n\n- Sleep log\n- Walks")
        XCTAssertTrue(plain.contains("Plan"))
        XCTAssertTrue(plain.contains("Continue weekly sessions."))
        XCTAssertTrue(plain.contains("Sleep log"))
        for symbol in ["**", "## ", "- Sleep"] {
            XCTAssertFalse(plain.contains(symbol), "found \(symbol)")
        }
    }
}

final class PatientArchiveWriterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let sessions = [
        session(date(2026, 3, 5), transcript: "March.", notes: [ArchiveNote(formatName: "GIRP", text: "G: March.")]),
        session(date(2026, 1, 5), transcript: "January."),
        session(date(2026, 2, 5), transcript: "February."),
    ]

    func testWritesAZipOfTheArchiveAndReportsProgressUpToOne() throws {
        let destination = root.appendingPathComponent("out.zip")
        var steps: [(Double, String)] = []
        let outcome = try PatientArchiveWriter.write(
            patientName: "Jane Doe", background: "Prefers mornings.", sessionCount: sessions.count,
            loadSession: { self.sessions[$0] }, to: destination, exportedOn: date(2026, 10, 21),
            progress: { steps.append(($0, $1)) }, isCancelled: { false }
        )
        let contents = try ZipContents(Data(contentsOf: destination))
        XCTAssertEqual(outcome.sessionCount, 3)
        XCTAssertEqual(outcome.fileCount, contents.items.count)
        XCTAssertEqual(outcome.byteCount, try Data(contentsOf: destination).count)
        XCTAssertEqual(contents.text("Jane Doe records/Patient notes.txt"), "Prefers mornings.\n")
        XCTAssertEqual(contents.text("Jane Doe records/Sessions/2026-01-05 09.30/Transcript.txt"), "January.\n")
        XCTAssertEqual(contents.text("Jane Doe records/Sessions/2026-03-05 09.30/Note - GIRP.txt"), "G: March.\n")

        XCTAssertEqual(steps.first?.1, "Reading session 1 of 3")
        XCTAssertEqual(steps.last?.0, 1)
        XCTAssertEqual(steps.map(\.0), steps.map(\.0).sorted(), "progress never goes backwards")
        XCTAssertTrue(steps.map(\.1).contains("Saving"))
    }

    func testCancellingWritesNothing() {
        let destination = root.appendingPathComponent("out.zip")
        var reads = 0
        XCTAssertThrowsError(try PatientArchiveWriter.write(
            patientName: "Jane", background: "", sessionCount: 3,
            loadSession: { reads += 1; return self.sessions[$0] }, to: destination,
            progress: { _, _ in }, isCancelled: { reads >= 1 }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(reads, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testAFailedReadFailsTheExportAndWritesNothing() {
        struct Unreadable: Error {}
        let destination = root.appendingPathComponent("out.zip")
        XCTAssertThrowsError(try PatientArchiveWriter.write(
            patientName: "Jane", background: "", sessionCount: 2,
            loadSession: { index in if index == 1 { throw Unreadable() }; return self.sessions[index] },
            to: destination, progress: { _, _ in }, isCancelled: { false }
        )) { XCTAssertTrue($0 is Unreadable) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testAPatientWithNoSessionsStillGetsAReadMe() throws {
        let destination = root.appendingPathComponent("empty.zip")
        let outcome = try PatientArchiveWriter.write(
            patientName: "Jane", background: "", sessionCount: 0, loadSession: { _ in fatalError() },
            to: destination, progress: { _, _ in }, isCancelled: { false }
        )
        XCTAssertEqual(outcome.sessionCount, 0)
        XCTAssertEqual(try ZipContents(Data(contentsOf: destination)).items.map(\.name), ["Jane records/Read me.txt"])
    }

    // MARK: Reading from a real store

    func testTheLoaderReadsTranscriptNotesAndCommentsFromAStore() throws {
        let dataRoot = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let commentStore = try XCTUnwrap(CommentStore(root: dataRoot))
        let store = Store(root: dataRoot, commentStore: commentStore)
        let patient = try store.createPatient(name: "Jane Doe")
        let record = try store.createSession(for: patient, on: date(2026, 1, 5))
        try store.saveTranscript("[00:05] Therapist: How was the week?", for: patient, session: record)
        try store.saveNote("## Subjective\n\nSlept **poorly**.", for: patient, session: record, format: .soap)
        commentStore.addComment(sessionID: record.id, quotedText: "How was the week?", body: "Open question.", anchorSeconds: 5)

        let loaded = try ArchiveLoader.load(store: store, patient: patient, session: record)
        XCTAssertEqual(loaded.date, record.date)
        XCTAssertEqual(loaded.transcript, "[00:05] Therapist: How was the week?")
        XCTAssertEqual(loaded.notes.map(\.formatName), ["SOAP"])
        XCTAssertTrue(loaded.notes[0].text.contains("Slept poorly."))
        XCTAssertFalse(loaded.notes[0].text.contains("**"))
        XCTAssertEqual(loaded.comments.map(\.body), ["Open question."])
        XCTAssertEqual(loaded.comments.first?.anchorSeconds, 5)
    }
}

@MainActor
final class ExportJobCenterTests: XCTestCase {
    private final class FakeNotifier: AppNotifying, @unchecked Sendable {
        private let lock = NSLock()
        private var asked = 0
        private var sent: [AppNotificationContent] = []

        var authorizationRequests: Int { lock.withLock { asked } }
        var posted: [AppNotificationContent] { lock.withLock { sent } }

        func requestAuthorization() async { lock.withLock { asked += 1 } }
        func post(_ content: AppNotificationContent) async { lock.withLock { sent.append(content) } }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
    }

    private var root: URL!
    private var notifier: FakeNotifier!
    private var center: ExportJobCenter!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        notifier = FakeNotifier()
        center = ExportJobCenter(notifier: notifier)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<600 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    private let sample = session(date(2026, 1, 5), transcript: "Hello.")

    func testAnExportRunsOffTheMainThreadThenReportsFinishedAndNotifies() async throws {
        let destination = root.appendingPathComponent("out.zip")
        let readOnMain = Flag()
        var finished: PatientArchiveWriter.Outcome?
        let sample = self.sample

        XCTAssertTrue(center.start(
            patientName: "Jane Doe", background: "", sessionCount: 2,
            load: { _ in if Thread.isMainThread { readOnMain.value = true }; return sample },
            destination: destination, onFinished: { finished = $0 }
        ))
        XCTAssertTrue(center.isRunning)
        try await wait { !self.center.isRunning }

        guard case let .finished(url, outcome) = center.state else { return XCTFail("state: \(center.state)") }
        XCTAssertEqual(url, destination)
        XCTAssertEqual(outcome.sessionCount, 2)
        XCTAssertEqual(finished, outcome)
        XCTAssertFalse(readOnMain.value, "sessions are read off the main thread")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        try await wait { !self.notifier.posted.isEmpty }
        XCTAssertEqual(notifier.posted, [SessionNotifications.exportReady()])
        XCTAssertEqual(notifier.authorizationRequests, 1)

        center.dismiss()
        XCTAssertEqual(center.state, .idle)
    }

    func testOnlyOneExportRunsAtATime() async throws {
        let started = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let sample = self.sample
        XCTAssertTrue(center.start(
            patientName: "A", background: "", sessionCount: 1,
            load: { _ in started.signal(); proceed.wait(); return sample },
            destination: root.appendingPathComponent("a.zip")
        ))
        XCTAssertFalse(center.start(
            patientName: "B", background: "", sessionCount: 1, load: { _ in sample },
            destination: root.appendingPathComponent("b.zip")
        ))
        center.dismiss()
        XCTAssertTrue(center.isRunning, "dismiss leaves a running export alone")
        proceed.signal()
        try await wait { !self.center.isRunning }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.zip").path))
    }

    func testCancellingStopsAfterTheSessionBeingReadAndWritesNothing() async throws {
        let started = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let sample = self.sample
        let destination = root.appendingPathComponent("out.zip")
        center.start(
            patientName: "Jane", background: "", sessionCount: 3,
            load: { _ in started.signal(); proceed.wait(); return sample }, destination: destination
        )
        try await wait { started.wait(timeout: .now()) == .success }

        center.cancel()
        guard case let .running(_, label) = center.state else { return XCTFail("state: \(center.state)") }
        XCTAssertEqual(label, "Cancelling")
        (0..<3).forEach { _ in proceed.signal() }
        try await wait { self.center.state == .idle }

        XCTAssertEqual(center.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(notifier.posted.isEmpty, "a cancelled export says nothing")
    }

    func testAFailedReadShowsAMessageAndNotifiesWithoutNamingAnyone() async throws {
        struct Unreadable: LocalizedError { var errorDescription: String? { "The transcript is locked." } }
        let destination = root.appendingPathComponent("out.zip")
        center.start(
            patientName: "Jane Doe", background: "", sessionCount: 1,
            load: { _ in throw Unreadable() }, destination: destination
        )
        try await wait { !self.center.isRunning }

        guard case let .failed(message) = center.state else { return XCTFail("state: \(center.state)") }
        XCTAssertTrue(message.contains("The transcript is locked."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try await wait { !self.notifier.posted.isEmpty }
        XCTAssertEqual(notifier.posted, [SessionNotifications.exportFailed()])
        XCTAssertTrue(center.start(
            patientName: "Jane", background: "", sessionCount: 0, load: { _ in fatalError() },
            destination: root.appendingPathComponent("again.zip")
        ), "a failed export doesn't block the next one")
        try await wait { !self.center.isRunning }
    }

    func testNotificationsNeverNameThePatientOrTheContents() {
        for notice in [SessionNotifications.exportReady(), SessionNotifications.exportFailed()] {
            XCTAssertFalse(notice.title.isEmpty)
            XCTAssertFalse(notice.body.isEmpty)
            XCTAssertEqual(notice.identifier, "records-export")
        }
    }

    func testMessagesForTheCommonFailures() {
        XCTAssertTrue(ExportJobCenter.message(for: ZipArchive.Failure.tooLarge).contains("too large"))
        XCTAssertTrue(ExportJobCenter.message(for: ZipArchive.Failure.tooManyEntries).contains("too large"))
        struct Other: LocalizedError { var errorDescription: String? { "Disk full." } }
        XCTAssertTrue(ExportJobCenter.message(for: Other()).contains("Disk full."))
    }

    func testStatusSummaryCountsSessionsAndFiles() {
        XCTAssertEqual(ExportStatusToast.summary(.init(sessionCount: 1, fileCount: 1, byteCount: 9)), "1 session, 1 file in a zip of text files.")
        XCTAssertEqual(ExportStatusToast.summary(.init(sessionCount: 12, fileCount: 31, byteCount: 9)), "12 sessions, 31 files in a zip of text files.")
    }
}
