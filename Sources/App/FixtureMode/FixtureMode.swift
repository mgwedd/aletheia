#if DEBUG
import AVFoundation
import Foundation
import SwiftUI

/// The state a UI test asks the app to start in, passed as JSON in the
/// `ALETHEIA_FIXTURE` environment variable of the launched app, for example
/// `{"run":"a1","patients":[{"name":"Jane Doe","sessions":2}],"fileVault":"on"}`.
struct FixtureScenario: Decodable, Equatable {
    struct PatientSeed: Decodable, Equatable {
        var name: String
        var sessions: Int?
        /// True when the patient has already attested to recording consent.
        var recordingConsent: Bool?
    }

    /// Names the throwaway data folder and defaults domain. Launching again
    /// with the same run reopens the same data; a new run starts empty.
    var run: String?
    var patients: [PatientSeed]?
    /// "on" (default), "off" or "unknown".
    var fileVault: String?
    /// "dev" (default) or "production".
    var tier: String?
    /// "off" (default) or "on". Off by default: the unlock sheet is the
    /// system's, which a UI test cannot answer, so it would cover the app.
    var appLock: String?
    /// "off" (default) or "on". On counts as a license that lets the app
    /// record and run the AI; off is the unlicensed app.
    var license: String?

    /// Replies the scripted AI engine gives, in order; the last repeats.
    var aiReplies: [String]?

    /// What "Import Audio…" is handed instead of the system open panel:
    /// "clip" (a two-second tone), "twoTracks" (a microphone and a call track,
    /// as Aletheia exports them), "threeFiles" (three tones) or "notAudio" (a
    /// text file named like audio).
    var importFile: String?

    /// The patient whose newest session is on screen at launch, so a test of a
    /// session screen does not depend on finding rows in the sidebar.
    var open: String?

    /// Settings > General > Recording consent: "firstSession" (default) or "everySession".
    var consentPolicy: String?

    var buildTier: BuildTier { tier == "production" ? .production : .dev }
    var appLockOn: Bool { appLock == "on" }
    var licenseOn: Bool { license == "on" }

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

    /// Fixture folders live beside, not inside, the scratch folder: the scratch
    /// folder is swept at every launch and a run's data must survive a relaunch.
    private static func fixtureFolder(_ name: String) -> URL {
        let url = PrivateStaging.root.deletingLastPathComponent()
            .appendingPathComponent("Fixture", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? SecureFS.createDirectory(at: url)
        return url
    }

    /// Inside the app's own container.
    static let root: URL = fixtureFolder("\(run)")

    /// Fixture bookkeeping kept beside, not inside, the data folder.
    private static let support: URL = fixtureFolder("\(run)-support")

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
        // Only on a run's first launch, so a relaunch keeps what the test changed.
        if isFirstLaunchOfRun {
            settings.appLockEnabled = scenario?.appLockOn ?? false
            if let policy = scenario?.consentPolicy.flatMap(ConsentPolicy.init(rawValue:)) {
                settings.recordingConsentPolicy = policy
            }
        }
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
        for seed in scenario?.patients ?? [] where seed.recordingConsent == true {
            if let patient = model.patients.first(where: { $0.name == seed.name }) {
                model.updatePatient(id: patient.id) { $0.recordingConsentAttestedAt = Date() }
            }
        }
    }

    /// Opens the scenario's `open` patient at their newest session.
    @MainActor static func openRequestedSession(_ model: AppModel) {
        guard let name = scenario?.open,
              let patient = model.patients.first(where: { $0.name == name }) else { return }
        let newest = (try? model.store?.listSessions(for: patient))?.max { $0.date < $1.date }
        AppNavigator.shared.requestOpen(patientID: patient.id)
        if let newest { AppNavigator.shared.requestOpenSession(patientID: patient.id, sessionID: newest.id) }
    }

    /// The files "Import Audio…" is given in a fixture run, written fresh into
    /// the fixture's own folder. Nil when the scenario names none.
    static func importFiles() -> [URL]? {
        guard let kind = scenario?.importFile else { return nil }
        let names: [String]
        switch kind {
        case "clip": names = ["import-clip.wav"]
        case "twoTracks": names = ["Recording - microphone.caf", "Recording - call.caf"]
        case "threeFiles": names = ["track 1.wav", "track 2.wav", "track 3.wav"]
        default: names = ["import-notes.m4a"]
        }
        return names.map { name in
            let url = support.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            if kind != "notAudio" {
                try? writeTone(to: url)
            } else {
                try? SecureFS.write(Data("these words are not audio".utf8), to: url)
            }
            return url
        }
    }

    private static func writeTone(to url: URL, seconds: Double = 2, rate: Double = 16_000) throws {
        let frames = AVAudioFrameCount(seconds * rate)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            samples[frame] = 0.3 * sin(2 * .pi * 440 * Float(frame) / Float(rate))
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ])
        try file.write(from: buffer)
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
        // Redrawn twice a second, so files written without a model change still show.
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Color.clear
                .frame(width: 2, height: 2)
                .accessibilityElement()
                .accessibilityIdentifier("fixture-probe")
                // The JSON rides in the label: XCUI reads a label back for any
                // element, but not always a value.
                .accessibilityLabel(FixtureProbe.snapshotJSON(appModel: appModel))
                .allowsHitTesting(false)
        }
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
        /// The patient's own consent policy; nil follows Settings.
        var consentPolicy: String?
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
                sessions: (try? appModel.store?.listSessions(for: patient).count) ?? 0,
                consentPolicy: patient.recordingConsentPolicy?.rawValue)
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
