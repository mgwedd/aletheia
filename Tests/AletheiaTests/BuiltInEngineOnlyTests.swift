import XCTest
@testable import Aletheia

/// The built-in llama.cpp engine is the only AI engine: no server to reach, so
/// nothing about the AI path can leave this Mac.
final class BuiltInEngineOnlyTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "BuiltInEngineOnlyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: Migration

    @MainActor
    func testStoredServerBackendMigratesToAutomaticAndIsRewritten() {
        let defaults = freshDefaults()
        defaults.set("ollama", forKey: "assistantBackend") // legacy-key
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.assistantBackend, .automatic)
        XCTAssertEqual(defaults.string(forKey: "assistantBackend"), "automatic")
    }

    @MainActor
    func testUnknownStoredBackendDecodesWithoutCrashing() {
        let defaults = freshDefaults()
        defaults.set("some-future-engine", forKey: "assistantBackend")
        XCTAssertEqual(AppSettings(defaults: defaults).assistantBackend, .automatic)
        XCTAssertEqual(defaults.string(forKey: "assistantBackend"), "automatic")
    }

    @MainActor
    func testKnownStoredBackendIsKept() {
        let defaults = freshDefaults()
        defaults.set(AssistantBackend.localLlama.rawValue, forKey: "assistantBackend")
        XCTAssertEqual(AppSettings(defaults: defaults).assistantBackend, .localLlama)
    }

    @MainActor
    func testRetiredServerSettingsAreRemovedOnLoad() {
        let defaults = freshDefaults()
        defaults.set("llama3.1:8b", forKey: "ollamaModelName") // legacy-key
        defaults.set("http://127.0.0.1:11434", forKey: "ollamaBaseURL") // legacy-key
        _ = AppSettings(defaults: defaults)
        for key in AppSettings.retiredKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) should be gone")
        }
        XCTAssertEqual(AppSettings.retiredKeys.count, 2)
    }

    // MARK: Unavailable engine

    func testUnavailableAssistantFailsEveryRequestWithAClearError() async {
        let assistant = UnavailableAssistant()
        let reachable = await assistant.isReachable()
        let hasModel = await assistant.hasModel("m")
        XCTAssertFalse(reachable)
        XCTAssertFalse(hasModel)

        func assertUnavailable(_ work: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
            do {
                try await work()
                XCTFail("expected a throw", file: file, line: line)
            } catch {
                XCTAssertEqual(error as? BuiltInModelUnavailableError, .unavailable, file: file, line: line)
            }
        }
        await assertUnavailable { _ = try await assistant.listModels() }
        await assertUnavailable { _ = try await assistant.generate(model: "m", system: "", prompt: "p") }
        await assertUnavailable { try await assistant.pullModel("m") { _, _ in } }
        await assertUnavailable { for try await _ in assistant.stream(model: "m", system: "", prompt: "p") {} }
    }

    func testUnavailableErrorSaysTheBuiltInModelIsUnavailable() {
        let message = BuiltInModelUnavailableError.unavailable.localizedDescription
        XCTAssertTrue(message.contains("built-in AI model"))
        XCTAssertTrue(message.contains("isn't available"))
    }

    // MARK: Fallbacks

    func testEveryPreferenceFallsBackToTheBuiltInEngine() {
        let resolver = AssistantBackendResolver(appleIntelligenceAvailable: false)
        for backend in AssistantBackend.allCases {
            XCTAssertEqual(resolver.resolve(backend), .localLlama)
        }
    }

    // MARK: No server code left

    /// "ollama" and the server's port must not appear anywhere under Sources/App.
    /// The one exception is the legacy settings key names (needed to clear them
    /// on load), whose lines carry a `legacy-key` marker comment.
    func testNoServerEngineReferencesRemainInTheAppSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in files {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.contains("// legacy-key") { continue }
                let lower = line.lowercased()
                if lower.contains("ollama") || lower.contains("11434") {
                    offenders.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan should have found the app sources")
        XCTAssertEqual(offenders, [])
    }
}
