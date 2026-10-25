@testable import Aletheia
import AVFoundation
import Compression
import Foundation
import PDFKit
import XCTest

// MARK: - Subjects

/// One export, started the way Settings and a patient's page start it.
@MainActor
final class ExportRun {
    let center: ExportJobCenter
    let notifier: ExportRecordingNotifier
    let destination: URL
    let parent: URL
    fileprivate let probe: DataFolderProbe
    fileprivate var afterSettling: () -> Void = {}

    fileprivate init(center: ExportJobCenter, notifier: ExportRecordingNotifier, destination: URL, probe: DataFolderProbe) {
        self.center = center
        self.notifier = notifier
        self.destination = destination
        self.probe = probe
        parent = destination.deletingLastPathComponent()
    }

    var state: ExportJobCenter.State { center.state }
    var postedNotifications: [AppNotificationContent] { notifier.posted }

    /// Waits until the job is no longer running.
    fileprivate func untilDone(timeout: TimeInterval = 20) async throws {
        try await eventually(within: timeout, "the export to stop running") { !self.center.isRunning }
        afterSettling()
    }

    /// Waits until nothing is left in the destination's parent (a cancelled export cleans up after itself).
    fileprivate func untilFolderIsClear(timeout: TimeInterval = 5) async throws {
        try await eventually(within: timeout, "the export folder to be clear") { self.leftInParent().isEmpty }
    }

    /// Waits for `count` notifications to have been posted.
    fileprivate func untilNotified(_ count: Int = 1, timeout: TimeInterval = 5) async throws {
        try await eventually(within: timeout, "\(count) notification(s) to be posted") { self.notifier.posted.count >= count }
    }

    /// Everything inside the destination's parent, hidden staging folders included.
    func leftInParent() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []).sorted()
    }
}

/// Records what the export asked the system to show.
final class ExportRecordingNotifier: AppNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [AppNotificationContent] = []
    private var authorizationRequests = 0

    var posted: [AppNotificationContent] { lock.lock(); defer { lock.unlock() }; return contents }
    var authorizationCount: Int { lock.lock(); defer { lock.unlock() }; return authorizationRequests }

    func requestAuthorization() async { lock.lock(); authorizationRequests += 1; lock.unlock() }
    func post(_ content: AppNotificationContent) async { lock.lock(); contents.append(content); lock.unlock() }
}

/// Holds an export inside its first session read until released.
final class ExportGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func waitUntilEntered() async {
        let entered = entered
        await withCheckedContinuation { c in DispatchQueue.global().async { entered.wait(); c.resume() } }
    }
    func open() { release.signal() }
    fileprivate func enterAndWait() { entered.signal(); release.wait() }
}

private struct GatedSource: AllRecordsSource {
    let inner: AllRecordsSource
    let gate: ExportGate
    var patients: [AllRecordsPatient] { inner.patients }
    var unreadablePatientCount: Int { inner.unreadablePatientCount }
    var unreadableSessionCount: Int { inner.unreadableSessionCount }
    func loadSession(patient: Int, session: Int) throws -> ArchiveSession {
        gate.enterAndWait()
        return try inner.loadSession(patient: patient, session: session)
    }
    func recordings(patient: Int, session: Int) -> [AllRecordsRecording] { inner.recordings(patient: patient, session: session) }
    func readableRecording(at url: URL) throws -> (url: URL, isTemporary: Bool) { try inner.readableRecording(at: url) }
}

/// The entries of a zip, by path, with their bytes.
struct ZipContents {
    let entries: [String: Data]
    var paths: [String] { entries.keys.sorted() }
}

/// The text of a note exported in one format, read back from the saved file.
struct SavedNoteFile {
    let format: ExportFormat
    let suggestedName: String
    let url: URL
    let readBackText: String
}

/// A folder of an export, listed.
struct ExportedFolder {
    let url: URL
    var children: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }
    func file(_ name: String) -> String? {
        try? String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
    }
}

/// What the app shows after an export: the toast line and the counts on disk.
@MainActor
struct ExportToast {
    let state: ExportJobCenter.State
    fileprivate let run: ExportRun
    var summary: String? {
        if case .finished(_, let outcome) = state { return ExportStatusToast.summary(outcome) }
        return nil
    }
    var outcome: PatientArchiveWriter.Outcome? {
        if case .finished(_, let outcome) = state { return outcome }
        return nil
    }
}

/// A session set up for a patient, as the verbs refer to it.
struct RecordedSession {
    fileprivate let patient: Patient
    fileprivate let record: SessionRecord
    /// "2026-09-16"
    var day: String { String(record.folderName.prefix(10)) }
    var longDate: String { record.date.formatted(date: .long, time: .omitted) }
}

/// A file type the note's Export menu offers.
enum NoteFileType {
    case pdf, word, markdown
    fileprivate var format: ExportFormat {
        switch self {
        case .pdf: return .pdf
        case .word: return .word
        case .markdown: return .markdown
        }
    }
}

/// Where the export is pointed.
enum ExportPlace {
    case anyFolderOnThisMac
    case folderThatCannotBeWritten
    case iCloudDrive
}

/// What picking a destination folder showed, and what was written there meanwhile.
struct ExportFolderChoice {
    let warnings: [ExportDestinationCheck.Warning]
    let filesWritten: Int
}

/// The Export menu on a note.
struct ExportMenu {
    let titles: [String]
    let preselected: String
}

/// The save panel for a patient's zip.
struct ZipSavePanel {
    let suggestedName: String
}

struct SessionFolderContents {
    let url: URL
    let files: [String]
    let recordingsPlay: Bool
}

// MARK: - Given

extension Given {
    /// A session with a transcript and the given notes (keyed by format name: "SOAP", "DAP", ...), comment and recordings.
    @discardableResult
    func exportSession(
        for patient: Patient, day: Int = 0, transcript: String = "Therapist: hello.\nClient: hi.",
        notes: [String: String] = [:], summary: String? = nil,
        comment: String? = nil, recordings: Bool = false
    ) throws -> RecordedSession {
        let store = try XCTUnwrap(app.appModel.store)
        var parts = DateComponents(year: 2026, month: 9, day: 16 + day, hour: 14, minute: 30)
        parts.calendar = Calendar.current
        let session = try store.createSession(for: patient, on: Calendar.current.date(from: parts)!)
        try store.saveTranscript(transcript, for: patient, session: session)
        if let summary { try store.saveSummary(summary, for: patient, session: session) }
        for (name, text) in notes {
            let format = try XCTUnwrap(ProgressNoteFormat.allCases.first { $0.shortName == name }, "no note format \(name)")
            try store.saveNote(text, for: patient, session: session, format: format)
        }
        if recordings {
            try Self.writeSilence(to: store.micRecordingURL(for: patient, session: session))
            try Self.writeSilence(to: store.callRecordingURL(for: patient, session: session))
        }
        if let comment, let comments = app.appModel.commentStore {
            _ = comments.addComment(sessionID: session.id, quotedText: "hello", body: comment)
        }
        app.appModel.refreshPatients()
        return RecordedSession(patient: patient, record: session)
    }

    fileprivate static func writeSilence(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        try file.write(from: buffer)
    }

    /// A destination folder name inside a fresh parent folder that this test owns.
    func newExportDestination(named name: String = "Aletheia records 2026-09-20") throws -> URL {
        let parent = app.root.deletingLastPathComponent()
            .appendingPathComponent("export-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent.appendingPathComponent(name, isDirectory: true)
    }
}

// MARK: - When

extension When {
    /// Export All Records, as Settings starts it, to a folder at `place`.
    @discardableResult
    func exportAllRecords(to place: ExportPlace = .anyFolderOnThisMac) throws -> ExportRun {
        var destination = try Given(app: app).newExportDestination()
        if place == .iCloudDrive {
            // A folder whose path sits in iCloud Drive's local mirror, kept under the temp root so nothing really syncs.
            let synced = destination.deletingLastPathComponent()
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
            try FileManager.default.createDirectory(at: synced, withIntermediateDirectories: true)
            destination = synced.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        }
        return try startAllRecords(destination: destination, gate: nil, unwritable: place == .folderThatCannotBeWritten)
    }

    /// Starts an export, cancels it while it is working, and lets it settle.
    func startExportAndCancelIt() async throws -> ExportRun {
        let gate = ExportGate()
        let run = try startAllRecords(destination: Given(app: app).newExportDestination(), gate: gate, unwritable: false)
        await gate.waitUntilEntered()
        run.center.cancel()
        gate.open()
        try await run.untilDone()
        try await run.untilFolderIsClear()
        return run
    }

    private func startAllRecords(destination: URL, gate: ExportGate?, unwritable: Bool) throws -> ExportRun {
        let store = try XCTUnwrap(app.appModel.store)
        let notifier = ExportRecordingNotifier()
        let center = ExportJobCenter(notifier: notifier)
        let on = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 20))!
        let parent = destination.deletingLastPathComponent()
        if unwritable { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path) }
        center.start(destination: destination) { progress, isCancelled in
            progress(0, "Listing patients")
            let source: AllRecordsSource = try StoreAllRecordsSource(store: store)
            return try AllRecordsExport.write(
                from: gate.map { GatedSource(inner: source, gate: $0) } ?? source,
                to: destination, exportedOn: on, progress: progress, isCancelled: isCancelled)
        }
        let run = ExportRun(center: center, notifier: notifier, destination: destination, probe: app.probe)
        run.afterSettling = {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        }
        return run
    }

    /// Waits for the export to finish (or fail) and for its notification, if any.
    func waitForExport(_ run: ExportRun) async throws {
        try await run.untilDone()
        try await run.untilNotified(run.state == .idle ? 0 : 1)
    }

    /// Export all records on a patient's page, as it starts the zip.
    func exportPatientZip(_ patient: Patient) throws -> ExportRun {
        let store = try XCTUnwrap(app.appModel.store)
        let sessions = try store.listSessions(for: patient)
        let notifier = ExportRecordingNotifier()
        let center = ExportJobCenter(notifier: notifier)
        let destination = try Given(app: app).newExportDestination(named: "Jane Doe - Records.zip")
        center.start(
            patientName: patient.name, background: patient.notes, sessionCount: sessions.count,
            load: { try ArchiveLoader.load(store: store, patient: patient, session: sessions[$0]) },
            destination: destination)
        return ExportRun(center: center, notifier: notifier, destination: destination, probe: app.probe)
    }

    func askToSavePatientZip(_ patient: Patient) -> ZipSavePanel {
        ZipSavePanel(suggestedName: FileSaver.fileName(patient.name, "Records") + ".zip")
    }

    func lookAtToast(_ run: ExportRun) -> ExportToast { ExportToast(state: run.state, run: run) }

    func pickExportFolder(_ place: ExportPlace) throws -> ExportFolderChoice {
        let folder: URL
        switch place {
        case .iCloudDrive:
            folder = try Given(app: app).newExportDestination().deletingLastPathComponent()
        default:
            folder = try Given(app: app).newExportDestination().deletingLastPathComponent()
        }
        let warnings = ExportDestinationInspector(encryption: app.disk, isUbiquitous: { _ in false }).warnings(for: folder)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.count ?? 0
        return ExportFolderChoice(warnings: warnings, filesWritten: written)
    }

    func openExportFolder(_ run: ExportRun) -> ExportedFolder { ExportedFolder(url: run.destination) }

    func openPatientFolder(_ name: String, in export: ExportedFolder) -> ExportedFolder {
        ExportedFolder(url: export.url.appendingPathComponent("\(name) records"))
    }

    func openSessionFolder(in patientFolder: ExportedFolder, index: Int = 0) throws -> SessionFolderContents {
        let sessions = patientFolder.url.appendingPathComponent("Sessions")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []).sorted()
        let name = try XCTUnwrap(names.indices.contains(index) ? names[index] : nil, "no session folder at \(index)")
        let url = sessions.appendingPathComponent(name)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
        let plays = files.filter { $0.hasSuffix(".caf") }.allSatisfy { file in
            guard let audio = try? AVAudioFile(forReading: url.appendingPathComponent(file)) else { return false }
            return audio.length > 0
        }
        return SessionFolderContents(url: url, files: files, recordingsPlay: plays)
    }

    func openZip(of run: ExportRun) throws -> ZipContents {
        ZipContents(entries: try MiniZip.read(Data(contentsOf: run.destination)))
    }

    func openExportMenu() -> ExportMenu {
        ExportMenu(titles: ExportFormat.allCases.map(\.title), preselected: ExportFormat.default.title)
    }

    /// Export a note as `type`, save it, and read it back.
    func exportNote(_ text: String, noteFormat: String = "SOAP", of session: RecordedSession, as type: NoteFileType) async throws -> SavedNoteFile {
        let patient = session.patient
        let format = type.format
        let base = FileSaver.fileName(patient.name, session.day, noteFormat)
        let name = format.fileName(base)
        let doc = ExportDocument(title: patient.name, subtitle: "\(noteFormat) · \(session.record.date.formatted(date: .abbreviated, time: .omitted))", markdown: text)
        let data = try XCTUnwrap(ExportRenderer.data(for: format, document: doc), "nothing rendered for \(format.title)")
        let url = app.root.deletingLastPathComponent().appendingPathComponent("note-\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return SavedNoteFile(format: format, suggestedName: name, url: url, readBackText: Self.readBack(url, format: format))
    }

    fileprivate static func readBack(_ url: URL, format: ExportFormat) -> String {
        switch format {
        case .pdf: return PDFDocument(url: url)?.string ?? ""
        case .markdown: return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        case .word:
            guard let data = try? Data(contentsOf: url),
                  let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
            else { return "" }
            return text.string
        }
    }

    /// Export a whole session from its header.
    func exportWholeSession(_ session: RecordedSession, as type: NoteFileType) async throws -> SavedNoteFile {
        let store = try XCTUnwrap(app.appModel.store)
        let format = type.format
        let base = FileSaver.fileName(session.patient.name, session.day)
        let data = try XCTUnwrap(ExportRenderer.data(
            for: format, document: ExportDocument(markdown: store.exportSessionMarkdown(patient: session.patient, session: session.record))))
        let url = app.root.deletingLastPathComponent().appendingPathComponent("session-\(UUID().uuidString)-\(format.fileName(base))")
        try data.write(to: url)
        return SavedNoteFile(format: format, suggestedName: format.fileName(base), url: url, readBackText: Self.readBack(url, format: format))
    }
}

// MARK: - Then

@MainActor
extension Then where Subject == ExportRun {
    func producedFolderOfPatients(_ names: [String]) {
        guard case .finished(let url, _) = subject.state else { return fail("expected the export to finish, state is \(subject.state)") }
        let parent = subject.leftInParent()
        expectEqual(parent, [url.lastPathComponent], "what the destination holds")
        expect(url.lastPathComponent.range(of: #"^Aletheia records \d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
               "expected a dated folder name, found \(url.lastPathComponent)")
        let children = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { $0 != Copy.exportReadMe }.sorted()
        expectEqual(children, names.map { "\($0) records" }.sorted(), "one folder per patient")
    }

    func leftNothingBehind() {
        expectEqual(subject.state, .idle, "the export toast after Cancel")
        expectEqual(subject.leftInParent(), [], "what is left in the destination")
    }

    /// The export was refused: it did not finish, and nothing was written to the folder.
    func refusedWithNothingWritten() {
        if case .finished = subject.state { fail("expected the export to be refused, but it finished") }
        expectEqual(subject.leftInParent(), [], "what was written to the synced folder")
    }

    func postedNothing() { expectEqual(subject.notifier.posted.count, 0, "notifications after Cancel") }

    func failedWithDidntFinish() {
        guard case .failed(let message) = subject.state else { return fail("expected the export to fail, state is \(subject.state)") }
        expect(message.hasPrefix(Copy.exportFailedPrefix), "expected \"\(Copy.exportFailedPrefix)…\", found \(message)")
        expectEqual(subject.notifier.posted.first?.title, Copy.exportFailedTitle, "the notification title")
    }

    func finishedAndNotifiedAsReady() {
        guard case .finished = subject.state else { return fail("expected the export to finish, state is \(subject.state)") }
        expectEqual(subject.notifier.posted.first?.title, Copy.exportReadyTitle, "the notification title")
    }
}

@MainActor
extension Then where Subject == ExportToast {
    func readsCounts(patients: Int, sessions: Int) {
        guard let summary = subject.summary else { return fail("expected a finished export, state is \(subject.state)") }
        let p = patients == 1 ? "1 patient" : "\(patients) patients"
        let s = sessions == 1 ? "1 session" : "\(sessions) sessions"
        expect(summary.hasPrefix("\(p), \(s), "), "expected \"\(p), \(s), …\", found \(summary)")
    }

    func countsMatchTheFilesWritten() {
        guard let outcome = subject.outcome else { return fail("expected a finished export") }
        let onDisk = subject.run.probe.files(under: subject.run.destination).count
        expectEqual(outcome.fileCount, onDisk, "files counted vs written")
    }
}

extension Then where Subject == ExportMenu {
    func offers(_ titles: [String], preselecting preselected: String) {
        expectEqual(subject.titles, titles, "the formats offered")
        expectEqual(subject.preselected, preselected, "the format preselected")
    }
}

extension Then where Subject == ZipSavePanel {
    func suggestsName(_ name: String) { expectEqual(subject.suggestedName, name, "the suggested zip name") }
}

extension Then where Subject == ExportFolderChoice {
    func warnsTheDiskIsntEncrypted() {
        expectEqual(subject.warnings.first?.title, Copy.exportDiskNotEncrypted, "the first warning")
    }
    func warnsOfNothing() { expectEqual(subject.warnings.map(\.title), [], "warnings") }
    func hasWrittenNothing() { expectEqual(subject.filesWritten, 0, "items written to the folder") }
}

extension Then where Subject == ExportedFolder {
    func readMeCounts(patients: Int, sessions: Int, recordings: Int) {
        let text = subject.file(Copy.exportReadMe) ?? ""
        for line in ["Patients: \(patients)", "Sessions: \(sessions)", "Recordings: \(recordings)"] {
            expect(text.contains(line), "expected \"\(Copy.exportReadMe)\" to say \"\(line)\", it reads:\n\(text)")
        }
    }

    func hasSessionFolders(_ count: Int, underPatient name: String) {
        let sessions = subject.url.appendingPathComponent("\(name) records/Sessions")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
        expectEqual(names.count, count, "dated session folders for \(name)")
        for n in names {
            expect(n.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}\.\d{2}( \(\d+\))?$"#, options: .regularExpression) != nil,
                   "expected a dated session folder, found \(n)")
        }
    }

    func hasPatientFolder(_ name: String) {
        expect(subject.children.contains(name), "expected a folder \"\(name)\", found \(subject.children)")
    }
}

extension Then where Subject == SessionFolderContents {
    func holds(_ files: [String]) { expectEqual(subject.files, files.sorted(), "the session folder's files") }
    func recordingsPlay() {
        expect(subject.files.contains { $0.hasSuffix(".caf") }, "expected recordings in the session folder")
        expect(subject.recordingsPlay, "expected the recordings to open and have audio")
    }
}

extension Then where Subject == ZipContents {
    func holdsOnlyTextFiles() {
        let other = subject.paths.filter { !$0.hasSuffix(".txt") }
        expectEqual(other, [], "non-text entries in the zip")
    }
    func hasEntry(_ path: String) { expect(subject.paths.contains(path), "expected \(path) in the zip, found \(subject.paths)") }
    func hasOneFolderPerSession(_ count: Int, under root: String) {
        let folders = Set(subject.paths.compactMap { path -> String? in
            let parts = path.split(separator: "/").map(String.init)
            return parts.count >= 3 && parts[0] == root && parts[1] == "Sessions" ? parts[2] : nil
        })
        expectEqual(folders.count, count, "session folders in the zip")
    }
}

extension Then where Subject == SavedNoteFile {
    func suggestsName(_ name: String) { expectEqual(subject.suggestedName, name, "the suggested file name") }
    func opensWith(_ fragments: [String]) {
        for f in fragments {
            expect(subject.readBackText.contains(f), "expected the \(subject.format.title) file to contain \"\(f)\", it reads:\n\(subject.readBackText.prefix(400))")
        }
    }
    func startsWith(_ prefix: String) {
        expect(subject.readBackText.hasPrefix(prefix), "expected the file to start with \"\(prefix)\", it starts \(subject.readBackText.prefix(40))")
    }
}

// MARK: - Zip reader

/// Reads a zip's central directory; stored and deflated entries only.
enum MiniZip {
    static func read(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard let eocd = (0...max(0, bytes.count - 22)).reversed().first(where: { bytes.count >= 22 && u32($0) == 0x06054b50 })
        else { throw NSError(domain: "MiniZip", code: 1) }
        let count = u16(eocd + 10)
        var cursor = u32(eocd + 16)
        var out: [String: Data] = [:]
        for _ in 0..<count {
            guard u32(cursor) == 0x02014b50 else { throw NSError(domain: "MiniZip", code: 2) }
            let method = u16(cursor + 10), compressed = u32(cursor + 20), size = u32(cursor + 24)
            let nameLen = u16(cursor + 28), extra = u16(cursor + 30), comment = u16(cursor + 32)
            let local = u32(cursor + 42)
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLen)], as: UTF8.self)
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            let raw = Data(bytes[start..<(start + compressed)])
            if method == 0 { out[name] = raw } else {
                var dst = [UInt8](repeating: 0, count: max(size, 1))
                let n = raw.withUnsafeBytes { src in
                    compression_decode_buffer(&dst, dst.count, src.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
                }
                out[name] = Data(dst[0..<n])
            }
            cursor += 46 + nameLen + extra + comment
        }
        return out
    }
}
