import XCTest
@testable import Aletheia

final class LegalReceiptTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegalReceiptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private var logURL: URL { tempRoot.appendingPathComponent(LegalReceipt.fileName) }

    func testAppendIsAppendOnlyAndOneLinePerAcceptance() throws {
        LegalReceipt.append(version: "2026-09-17", at: Date(timeIntervalSince1970: 0), root: tempRoot, appVersion: "1.5.0")
        LegalReceipt.append(version: "2026-10-01", at: Date(timeIntervalSince1970: 60), root: tempRoot, appVersion: "1.6.0")

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2, "each acceptance appends exactly one line, keeping earlier ones")

        // Earlier entry is preserved (append-only, not overwritten).
        let first = try JSONDecoder().decode(LegalReceipt.Entry.self, from: Data(lines[0].utf8))
        XCTAssertEqual(first.acceptedVersion, "2026-09-17")
        XCTAssertEqual(first.appVersion, "1.5.0")

        let second = try JSONDecoder().decode(LegalReceipt.Entry.self, from: Data(lines[1].utf8))
        XCTAssertEqual(second.acceptedVersion, "2026-10-01")
    }

    func testTimestampIsIso8601Utc() throws {
        LegalReceipt.append(version: "v", at: Date(timeIntervalSince1970: 0), root: tempRoot, appVersion: "1.0.0")
        let line = try String(contentsOf: logURL, encoding: .utf8)
        let entry = try JSONDecoder().decode(LegalReceipt.Entry.self, from: Data(line.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        XCTAssertEqual(entry.acceptedAt, "1970-01-01T00:00:00Z")
    }

    func testNilRootIsNoOp() {
        LegalReceipt.append(version: "v", at: Date(), root: nil, appVersion: "1.0.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
    }
}
