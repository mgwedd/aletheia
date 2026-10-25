#if DEBUG
import Foundation
import SwiftUI

/// The state a UI test asks the app to start in, passed as JSON in the
/// `ALETHEIA_FIXTURE` environment variable of the launched app, for example
/// `{"run":"a1","patients":[{"name":"Jane Doe","sessions":2}],"fileVault":"on"}`.
struct FixtureScenario: Decodable, Equatable {
    struct PatientSeed: Decodable, Equatable {
        var name: String
        var sessions: Int?
    }

    /// Names the throwaway data folder and defaults domain. Launching again
    /// with the same run reopens the same data; a new run starts empty.
    var run: String?
    var patients: [PatientSeed]?
    /// "on" (default), "off" or "unknown".
    var fileVault: String?
    /// "dev" (default) or "production".
    var tier: String?

    /// Replies the scripted AI engine gives, in order; the last repeats.
    var aiReplies: [String]?

    var buildTier: BuildTier { tier == "production" ? .production : .dev }

    struct Malformed: Error, CustomStringConvertible {
        let detail: String
        var description: String { "ALETHEIA_FIXTURE is not a valid scenario: \(detail)" }
    }

    /// Reads a scenario. Anything unreadable throws: a typo in a scenario must
    /// stop the run, never silently start the app in some other state.
    static func parse(_ json: String) throws -> FixtureScenario {
        do {
            return try JSONDecoder().decode(FixtureScenario.self, from: Data(json.utf8))
        } catch {
            throw Malformed(detail: String(describing: error))
        }
    }
}

/// Hermetic world for UI tests. Only compiled into Debug builds; Release has no
/// trace of it (see `FixtureModeReleaseTests`).
enum FixtureMode {
    static let environmentKey = "ALETHEIA_FIXTURE"

    static let scenario: FixtureScenario? = {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        do { return try FixtureScenario.parse(raw) } catch { fatalError("\(error)") }
    }()

    static var isActive: Bool { scenario != nil }

    private static var run: String { scenario?.run ?? "default" }

    /// Inside the app's own container: the sandbox temp folder.
    static let root: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aletheia-fixture-\(run)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Fixture bookkeeping kept beside, not inside, the data folder.
    private static let support: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aletheia-fixture-\(run)-support", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let suiteName = "com.aletheia.fixture.\(run)"

    static let defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard

    private static var seededMarker: URL { support.appendingPathComponent("seeded") }

    /// A fresh run: first launch for this run name.
    static var isFirstLaunchOfRun: Bool { !FileManager.default.fileExists(atPath: seededMarker.path) }

    static let engine = FixtureScriptedEngine(replies: scenario?.aiReplies ?? [])

    /// The assistant the fixture build uses: the real prompt-building over the
    /// scripted engine. The model file is a placeholder so it reads as present.
    static var assistant: Assistant {
        let model = support.appendingPathComponent("fixture-model.gguf")
        if !FileManager.default.fileExists(atPath: model.path) {
            FileManager.default.createFile(atPath: model.path, contents: Data())
        }
        return LlamaAssistant(modelURL: model, engineOverride: engine)
    }

    static let disk = FixtureDisk(state: scenario?.fileVault)
    static let deviceKeys = ProcessMemoryDeviceKeyStore()

    /// Settings as a user who finished first run in a chosen folder.
    static func prepare(_ settings: AppSettings) {
        settings.dataRootURL = root
        settings.hasCompletedFirstRun = true
        if !settings.hasAcceptedCurrentLegal { settings.recordLegalAcceptance() }
    }

    /// Builds the scenario's data once per run, before the first window exists.
    @MainActor static func seed(_ model: AppModel) {
        guard isFirstLaunchOfRun else { return }
        defer { FileManager.default.createFile(atPath: seededMarker.path, contents: Data()) }
        guard let store = model.store else { return }
        for seed in scenario?.patients ?? [] {
            guard let patient = try? store.createPatient(name: seed.name) else { continue }
            for offset in 0..<(seed.sessions ?? 0) {
                _ = try? store.createSession(for: patient, on: Date().addingTimeInterval(Double(offset) * 86_400))
            }
        }
        model.refreshPatients()
    }
}

/// FileVault answer for the scenario.
final class FixtureDisk: DiskEncryptionProbing {
    private let state: String?
    init(state: String?) { self.state = state }

    func isDataVolumeEncrypted(_ url: URL) -> Bool? {
        switch state {
        case "off": return false
        case "unknown": return nil
        default: return true
        }
    }
}

/// A clock the test moves by hand.
final class FixtureClock {
    private(set) var now: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_767_225_600)) { now = start }
    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// A local model that answers from a script, in order (the last reply
/// repeats), and keeps every request it was given so a test can see exactly
/// what context reached the model.
final class FixtureScriptedEngine: LocalLLMEngine {
    static let defaultReply = "Fixture reply."

    var state: LocalLLMEngineState = .ready
    private let replies: [String]
    private let lock = NSLock()
    private var received: [LocalLLMRequest] = []
    private var next = 0

    init(replies: [String] = []) { self.replies = replies }

    var requests: [LocalLLMRequest] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    func load() async throws {}
    func unload() {}

    func generate(_ request: LocalLLMRequest) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        received.append(request)
        guard !replies.isEmpty else { return Self.defaultReply }
        defer { next += 1 }
        return replies[min(next, replies.count - 1)]
    }
}

/// Spotlight stays untouched in a fixture run.
struct FixtureSpotlight: SpotlightIndexing {
    func replaceIndex(with entries: [SpotlightEntry]) {}
    func clear() {}
}

/// An invisible accessibility element whose value is a JSON snapshot of facts
/// a test cannot see on screen. The test reads it through XCUI and never opens
/// the app's container.
struct FixtureProbeOverlay: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("fixture-probe")
            .accessibilityLabel("fixture probe")
            .accessibilityValue(FixtureProbe.snapshotJSON(appModel: appModel))
            .allowsHitTesting(false)
    }
}

enum FixtureProbe {
    struct PatientFacts: Codable, Equatable {
        var name: String
        var notes: String
        var clinicalHistory: String
        var medications: [String]
        var folderExists: Bool
        var sessions: Int
    }

    struct Snapshot: Codable, Equatable {
        var files: [String]
        var patients: [PatientFacts]
        /// Every prompt the AI engine was given: system text, earlier turns
        /// and the final prompt, joined, one entry per request.
        var aiRequests: [String]
    }

    /// Stable text: keys sorted, so equal facts always read the same.
    static func encode(_ snapshot: Snapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(snapshot)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func decode(_ json: String) throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    }

    /// Relative paths of every regular file under `root`, sorted.
    static func files(under root: URL) -> [String] {
        let root = root.standardizedFileURL
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let prefix = root.path + "/"
        return walker.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { $0.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "") }
            .sorted()
    }

    @MainActor static func snapshot(appModel: AppModel) -> Snapshot {
        let stored = (try? appModel.store?.listPatients()) ?? []
        let patients = stored.map { patient -> PatientFacts in
            let dir = appModel.store?.patientDir(for: patient)
            return PatientFacts(
                name: patient.name, notes: patient.notes, clinicalHistory: patient.clinicalHistory,
                medications: patient.medications.map { "\($0.name) \($0.dose)" },
                folderExists: dir.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                sessions: (try? appModel.store?.listSessions(for: patient).count) ?? 0)
        }
        let asked = FixtureMode.engine.requests.map { request in
            ([request.system] + request.turns.map { "\($0)" } + [request.prompt]).joined(separator: "\n")
        }
        return Snapshot(files: files(under: FixtureMode.root), patients: patients, aiRequests: asked)
    }

    @MainActor static func snapshotJSON(appModel: AppModel) -> String {
        encode(snapshot(appModel: appModel))
    }
}
#endif
