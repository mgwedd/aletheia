import XCTest
@testable import Aletheia

private struct StubTranscriber: Transcribing {
    var isReady: Bool { true }
    func transcribeSession(
        micURL: URL?, callURL: URL?, onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> String { "stub transcript" }
}

private final class StubNotifier: AppNotifying {
    private(set) var authorizationRequests = 0
    func requestAuthorization() async { authorizationRequests += 1 }
    func post(_ content: AppNotificationContent) async {}
}

private final class StubEngine: LocalLLMEngine {
    var state: LocalLLMEngineState = .notLoaded
    func load() async throws {}
    func unload() {}
    func generate(_ request: LocalLLMRequest) async throws -> String { "stub reply" }
}

private struct NoSpotlight: SpotlightIndexing {
    func replaceIndex(with entries: [SpotlightEntry]) {}
    func clear() {}
}

private final class Ticks: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func tick() -> Date { lock.lock(); defer { lock.unlock() }; count += 1; return Date(timeIntervalSince1970: 1_000) }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// The test-only stand-ins for the transcriber, model, notifier and clock.
/// Production builds pass none of them and keep the real ones.
@MainActor
final class InjectionSeamTests: XCTestCase {
    private func makeSettings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "seam-\(UUID().uuidString)")!)
    }

    func testDefaultsKeepTheRealTranscriberAndNotifier() {
        let integrations = Integrations(settings: makeSettings())
        XCTAssertTrue(integrations.makeTranscriber() is WhisperTranscriber)
        XCTAssertTrue(integrations.makeNotifier() is UserNotificationService)
    }

    func testAnInjectedTranscriberIsUsed() {
        let integrations = Integrations(settings: makeSettings(), transcriber: StubTranscriber())
        XCTAssertTrue(integrations.makeTranscriber() is StubTranscriber)
    }

    func testAnInjectedNotifierIsUsedEveryTime() async {
        let notifier = StubNotifier()
        let integrations = Integrations(settings: makeSettings(), notifier: notifier)
        await integrations.makeNotifier().requestAuthorization()
        await integrations.makeNotifier().requestAuthorization()
        XCTAssertEqual(notifier.authorizationRequests, 2)
    }

    #if canImport(llama)
    func testAnInjectedEngineAnswersEvenWithNoModelFile() async throws {
        let integrations = Integrations(settings: makeSettings(), engine: StubEngine())
        let reply = try await integrations.makeAssistant().generate(model: "m", system: "s", prompt: "p")
        XCTAssertEqual(reply, "stub reply")
    }

    func testWithoutAnInjectedEngineTheModelFileDecidesAvailability() async {
        let integrations = Integrations(settings: makeSettings())
        let reachable = await integrations.makeAssistant().isReachable()
        XCTAssertEqual(reachable, FileManager.default.fileExists(atPath: integrations.llamaModelURL.path))
    }
    #endif

    func testTheClockReachesTheDigestScheduler() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ticks = Ticks()
        let integrations = Integrations(settings: makeSettings(), now: { ticks.tick() })
        let scheduler = integrations.digestScheduler
        let service = AssistantService(assistant: UnavailableAssistant(), model: "m", systemPrompt: "s")
        scheduler.attach(
            context: { .init(store: Store(root: root), patients: [], service: service) },
            activity: { DigestActivity() })
        defer { scheduler.stop() }
        scheduler.evaluate()
        for _ in 0..<100 where ticks.value == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertGreaterThan(ticks.value, 0, "the scan schedule reads the injected clock")
    }

    func testTheClockStampsATranscriptionJob() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "seam-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.dataRootURL = root
        let encryption = EncryptionManager(
            dataRootProvider: { root }, deviceKeys: ProcessMemoryDeviceKeyStore(), defaults: defaults)
        let model = AppModel(
            settings: settings, encryption: encryption, spotlightIndexer: NoSpotlight(),
            featureRegistry: .compose(tier: .dev, from: FeatureRegistry.allModules))
        let store = try XCTUnwrap(model.store)
        let patient = try store.createPatient(name: "Seam Patient")
        let session = try store.createSession(for: patient)

        let fixed = Date(timeIntervalSince1970: 42)
        let coordinator = TranscriptionCoordinator(
            appModel: model, integrations: Integrations(settings: settings, transcriber: StubTranscriber(), notifier: StubNotifier()),
            settings: settings, now: { fixed })
        coordinator.start(patient: patient, session: session)
        XCTAssertEqual(coordinator.job(for: session.id)?.startedAt, fixed)
        coordinator.cancel(sessionID: session.id)
    }
}
