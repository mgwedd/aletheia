import XCTest
@testable import Aletheia

/// A damaged interrupted-work list never crashes the launch and is never
/// destroyed: whatever was in it stays on disk for recovery.
final class InterruptedWorkLedgerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterruptedWorkLedgerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var ledger: InterruptedWorkLedger { InterruptedWorkLedger(dataRoot: root) }

    private func item(_ folder: String) -> InterruptedWork {
        InterruptedWork(kind: .transcription, patientID: UUID(), sessionFolder: folder)
    }

    private func damagedContents() -> [String: Data] {
        let valid = (try? JSONEncoder().encode([item("ok")])) ?? Data()
        return [
            "empty file": Data(),
            "binary noise": Data([0xFF, 0x00, 0xFE, 0x13, 0x37]),
            "truncated": valid.prefix(valid.count / 2),
            "wrong shape": Data(#"{"kind":"transcription"}"#.utf8),
            "unknown kind": Data(
                #"[{"kind":"holodeck","patientID":"\#(UUID().uuidString)","sessionFolder":"s"}]"#.utf8),
            "bad patient id": Data(#"[{"kind":"digest","patientID":"nope","sessionFolder":"s"}]"#.utf8),
        ]
    }

    func testAnUnreadableListLoadsAsEmptyWithoutTouchingTheFile() throws {
        for (label, bytes) in damagedContents() {
            try bytes.write(to: ledger.url)
            XCTAssertEqual(ledger.load(), [], label)
            XCTAssertEqual(try Data(contentsOf: ledger.url), bytes, "\(label): left as it was")
        }
    }

    func testRecordingNewWorkKeepsTheUnreadableListAsideAndStoresTheNewWork() throws {
        for (label, bytes) in damagedContents() {
            try? FileManager.default.removeItem(at: ledger.unreadableCopyURL)
            try bytes.write(to: ledger.url)
            let new = item("new")

            ledger.record([new])

            XCTAssertEqual(ledger.load(), [new], label)
            XCTAssertEqual(try Data(contentsOf: ledger.unreadableCopyURL), bytes, "\(label): the old bytes survive")
        }
    }

    func testClearingNeverDeletesAnUnreadableList() throws {
        let bytes = Data("{not json".utf8)
        try bytes.write(to: ledger.url)

        ledger.save([])

        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.url.path))
        XCTAssertEqual(try Data(contentsOf: ledger.unreadableCopyURL), bytes)
    }

    func testASecondUnreadableListDoesNotReplaceTheFirstOneKeptAside() throws {
        let first = Data("first damaged".utf8)
        let second = Data("second damaged".utf8)
        try first.write(to: ledger.url)
        ledger.record([item("a")])
        try second.write(to: ledger.url)

        ledger.record([item("b")])

        XCTAssertEqual(try Data(contentsOf: ledger.unreadableCopyURL), first)
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".interrupted-work.unreadable") }
        XCTAssertEqual(kept.count, 2)
        let contents = try kept.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        XCTAssertTrue(contents.contains(second))
    }

    func testAReadableListIsNotSetAside() {
        let a = item("a"), b = item("b")
        ledger.record([a])
        ledger.record([b])
        XCTAssertEqual(ledger.load(), [a, b])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.unreadableCopyURL.path))
    }
}
