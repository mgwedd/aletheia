import XCTest

/// The app promises it spawns no subprocesses (README, entitlements).
final class NoSubprocessTests: XCTestCase {
    func testAppSourcesNeverSpawnProcesses() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = repo.appendingPathComponent("Sources/App")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let spawn = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])Process\("#)
        var checked = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            checked += 1
            let whole = NSRange(text.startIndex..., in: text)
            XCTAssertNil(spawn.firstMatch(in: text, range: whole), "Process( in \(file.lastPathComponent)")
            XCTAssertFalse(text.contains("posix_spawn"), "posix_spawn in \(file.lastPathComponent)")
        }
        XCTAssertGreaterThan(checked, 50, "the scan should see the app sources")
    }
}
