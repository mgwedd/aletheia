import XCTest
@testable import Aletheia

/// The license may only ever stop two things: starting a new recording and running AI.
/// Opening, reading, searching, exporting and deleting existing records never ask it.
/// These guards read the sources: any file that touches the license gate must be on the
/// list below, and none of those files handles stored records.
final class LicenseGateScopeTests: XCTestCase {
    private var repo: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func sources() throws -> [(path: String, text: String)] {
        let root = repo.appendingPathComponent("Sources/App")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var files: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append((String(url.path.dropFirst(repo.path.count + 1)), try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    /// Anything that asks the license a question (as opposed to describing it).
    private let gateTokens = ["licenseRefusal", "newWorkRefusal", "authorizeNewWork", "LicenseState", "LicenseBlockedError", ".authorize()"]

    /// Files allowed to ask: the gate itself, the two entry points it guards and the
    /// places that wire or show it. None of them opens, searches, exports or deletes records.
    private let allowed: Set<String> = [
        "Sources/App/Services/License/LicenseState.swift",
        "Sources/App/Services/SessionRecorder.swift",          // new recording
        "Sources/App/Services/InferenceQueue.swift",           // AI
        "Sources/App/Views/ChatStreamRunner.swift",            // AI: notes and chat
        "Sources/App/Services/Digest/DigestBuilder.swift",     // AI: background digests
        "Sources/App/AletheiaApp.swift",                       // wiring
        "Sources/App/Views/RootView.swift",                    // banner
        "Sources/App/Views/FirstRunView.swift",                // first-run license step
        "Sources/App/Views/LicenseViews.swift",                // entry field, banner, pane
    ]

    func testOnlyRecordingAndAIAskTheLicense() throws {
        var offenders: [String] = []
        for (path, text) in try sources() where !allowed.contains(path) {
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for token in gateTokens where code.contains(token) { offenders.append("\(path): \(token)") }
        }
        XCTAssertEqual(offenders, [], "only new recording and AI may consult the license")
    }

    func testRecordsAreReadSearchedExportedAndDeletedWithoutTheLicense() throws {
        let recordPaths = [
            "Sources/App/Services/Store.swift",
            "Sources/App/Services/PatientArchive.swift",
            "Sources/App/Services/ExportJobCenter.swift",
            "Sources/App/Services/ExportFormat.swift",
            "Sources/App/Services/MarkdownExporter.swift",
            "Sources/App/Services/NotePDF.swift",
            "Sources/App/Services/SessionQueries.swift",
            "Sources/App/Services/TextSearch.swift",
            "Sources/App/Services/AppModel.swift",
            "Sources/App/Services/Repositories",
            "Sources/App/Services/Search",
        ]
        let all = try sources()
        for prefix in recordPaths {
            let matched = all.filter { $0.path == prefix || $0.path.hasPrefix(prefix + "/") }
            XCTAssertFalse(matched.isEmpty, "\(prefix) should exist; update this list if it moved")
            for (path, text) in matched {
                for token in gateTokens {
                    XCTAssertFalse(text.contains(token), "\(path) must not consult the license (\(token))")
                }
            }
        }
    }

    func testTheTwoGuardedEntryPointsDoAskTheLicense() throws {
        let all = Dictionary(uniqueKeysWithValues: try sources().map { ($0.path, $0.text) })
        let recorder = try XCTUnwrap(all["Sources/App/Services/SessionRecorder.swift"])
        let start = try XCTUnwrap(recorder.range(of: "func start(micURL"))
        XCTAssertTrue(recorder.contains("licenseRefusal?()"))
        let afterStart = String(recorder[start.lowerBound...].prefix(600))
        XCTAssertTrue(afterStart.contains("licenseRefusal?()"), "start(...) must ask before doing anything")
        XCTAssertTrue(try XCTUnwrap(all["Sources/App/Views/ChatStreamRunner.swift"]).contains("try queue.authorize()"))
        XCTAssertTrue(try XCTUnwrap(all["Sources/App/Services/Digest/DigestBuilder.swift"]).contains("try queue.authorize()"))
    }

    /// Where the shipped app installs the gate: both the recorder and the AI queue.
    func testTheAppInstallsTheGateOnTheRecorderAndTheQueue() throws {
        let app = try String(contentsOf: repo.appendingPathComponent("Sources/App/AletheiaApp.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("recorder.licenseRefusal ="))
        XCTAssertTrue(app.contains("inferenceQueue.licenseRefusal ="))
    }
}
