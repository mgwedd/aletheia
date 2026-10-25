#if DEBUG
import XCTest
@testable import Aletheia

final class FixtureScenarioTests: XCTestCase {
    func testParsesAFullScenario() throws {
        let scenario = try FixtureScenario.parse(
            #"{"run":"r1","patients":[{"name":"Jane Doe","sessions":2},{"name":"John Roe"}],"fileVault":"off","tier":"production","aiReplies":["a","b"]}"#)
        XCTAssertEqual(scenario.run, "r1")
        XCTAssertEqual(scenario.patients, [.init(name: "Jane Doe", sessions: 2), .init(name: "John Roe", sessions: nil)])
        XCTAssertEqual(scenario.fileVault, "off")
        XCTAssertEqual(scenario.buildTier, .production)
        XCTAssertEqual(scenario.aiReplies, ["a", "b"])
    }

    func testEmptyObjectIsTheDefaultScenario() throws {
        let scenario = try FixtureScenario.parse("{}")
        XCTAssertNil(scenario.patients)
        XCTAssertEqual(scenario.buildTier, .dev)
    }

    func testMalformedJSONThrowsInsteadOfFallingBack() {
        for bad in ["", "not json", #"{"patients":"Jane"}"#, #"{"patients":[{"sessions":1}]}"#, "[1,2]"] {
            XCTAssertThrowsError(try FixtureScenario.parse(bad), "\(bad) should not parse") { error in
                XCTAssertTrue(error is FixtureScenario.Malformed)
                XCTAssertTrue("\(error)".hasPrefix("ALETHEIA_FIXTURE is not a valid scenario"))
            }
        }
    }
}

final class FixtureClockTests: XCTestCase {
    func testStartsAtAFixedInstantAndOnlyMovesWhenAdvanced() {
        let clock = FixtureClock()
        XCTAssertEqual(clock.now, FixtureClock().now)
        let start = clock.now
        clock.advance(by: 90)
        XCTAssertEqual(clock.now.timeIntervalSince(start), 90)
        clock.advance(by: 86_400)
        XCTAssertEqual(clock.now.timeIntervalSince(start), 86_490)
    }
}

final class FixtureScriptedEngineTests: XCTestCase {
    func testRepliesInOrderThenRepeatsTheLast() async throws {
        let engine = FixtureScriptedEngine(replies: ["one", "two"])
        let first = try await engine.generate(LocalLLMRequest(prompt: "p1"))
        let second = try await engine.generate(LocalLLMRequest(prompt: "p2"))
        let third = try await engine.generate(LocalLLMRequest(prompt: "p3"))
        XCTAssertEqual([first, second, third], ["one", "two", "two"])
    }

    func testWithoutAScriptItGivesTheDefaultReply() async throws {
        let engine = FixtureScriptedEngine()
        let reply = try await engine.generate(LocalLLMRequest(prompt: "p"))
        XCTAssertEqual(reply, FixtureScriptedEngine.defaultReply)
    }

    func testRecordsEverythingItWasGiven() async throws {
        let engine = FixtureScriptedEngine()
        _ = try await engine.generate(LocalLLMRequest(system: "sys", prompt: "ask about Biscuit"))
        _ = try await engine.generate(LocalLLMRequest(prompt: "second"))
        XCTAssertEqual(engine.requests.map(\.prompt), ["ask about Biscuit", "second"])
        XCTAssertEqual(engine.requests.first?.system, "sys")
    }
}

final class FixtureProbeTests: XCTestCase {
    private let snapshot = FixtureProbe.Snapshot(
        files: ["Jane/session/notes.txt", "audit.log"],
        patients: [.init(name: "Jane Doe", notes: "n", clinicalHistory: "", medications: ["Sertraline 50 mg"],
                         folderExists: true, sessions: 2)],
        aiRequests: ["sys\nprompt"])

    func testSnapshotRoundTrips() throws {
        XCTAssertEqual(try FixtureProbe.decode(FixtureProbe.encode(snapshot)), snapshot)
    }

    func testEncodingIsStable() {
        XCTAssertEqual(FixtureProbe.encode(snapshot), FixtureProbe.encode(snapshot))
        XCTAssertTrue(FixtureProbe.encode(snapshot).hasPrefix(#"{"aiRequests":["#), "keys are sorted")
    }

    func testFilesListsRegularFilesRelativeAndSorted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("b/c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("z.txt"))
        try Data("x".utf8).write(to: nested.appendingPathComponent("a.txt"))
        XCTAssertEqual(FixtureProbe.files(under: root), ["b/c/a.txt", "z.txt"])
    }

    func testFilesOfAMissingFolderIsEmpty() {
        XCTAssertEqual(FixtureProbe.files(under: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")), [])
    }
}

final class FixtureDiskTests: XCTestCase {
    func testAnswersPerScenario() {
        let url = URL(fileURLWithPath: "/tmp")
        XCTAssertEqual(FixtureDisk(state: nil).isDataVolumeEncrypted(url), true)
        XCTAssertEqual(FixtureDisk(state: "on").isDataVolumeEncrypted(url), true)
        XCTAssertEqual(FixtureDisk(state: "off").isDataVolumeEncrypted(url), false)
        XCTAssertNil(FixtureDisk(state: "unknown").isDataVolumeEncrypted(url))
    }
}

/// Fixture mode must not exist in a shipped build.
final class FixtureModeReleaseGuardTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func swiftFiles(under sub: String) -> [URL] {
        let base = repo.appendingPathComponent(sub)
        let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        return (walker?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
    }

    func testEveryFixtureFileIsWhollyDebugOnly() throws {
        let files = swiftFiles(under: "Sources/App/FixtureMode")
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            XCTAssertEqual(lines.first, "#if DEBUG", "\(file.lastPathComponent) must open with #if DEBUG")
            XCTAssertEqual(lines.last, "#endif", "\(file.lastPathComponent) must close with #endif")
        }
    }

    func testNoOtherSourceUsesFixtureModeOutsideADebugBlock() throws {
        let outside = swiftFiles(under: "Sources").filter { !$0.path.contains("/FixtureMode/") }
        for file in outside {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("FixtureMode") || text.contains("FixtureProbe") else { continue }
            var depth = 0
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if") { depth += 1 }
                if trimmed == "#endif" { depth -= 1 }
                if line.contains("FixtureMode") || line.contains("FixtureProbe") {
                    XCTAssertGreaterThan(depth, 0, "\(file.lastPathComponent):\(number + 1) uses fixture mode outside #if")
                }
            }
        }
    }

    func testReleaseBinaryCheckRejectsFixtureStrings() throws {
        let script = repo.appendingPathComponent("scripts/check-entitlements.sh")
        let result = try run(script, arguments: ["--self-test"])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("self-test OK"), result.output)
    }

    private func run(_ script: URL, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = script
        process.arguments = arguments
        process.currentDirectoryURL = repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
#endif
