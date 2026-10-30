#if DEBUG
import AVFoundation
import Foundation
import SwiftUI

extension FixtureScenario {
    var buildTier: BuildTier { tier == "production" ? .production : .dev }
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

    static let engine = FixtureScriptedEngine(
        replies: scenario?.aiReplies ?? [], rules: scenario?.aiRules ?? [],
        stageMs: scenario?.aiStageMs ?? 0, parts: scenario?.aiParts ?? 0,
        missing: scenario?.aiModelMissing == true, words: scenario?.aiStreamsWords == true)

    /// The transcript view on screen, so the probe can count its laid-out lines.
    @MainActor static weak var transcriptView: NSTextView?

    /// The transcriber the fixture build uses, or nil for the real one.
    static var transcriber: Transcribing? {
        scenario?.slowTranscription == true ? FixtureSlowTranscriber() : nil
    }

    /// The assistant the fixture build uses: the real prompt-building over the
    /// scripted engine. The model file is a placeholder so it reads as present.
    static var modelURL: URL {
        let model = support.appendingPathComponent("fixture-model.gguf")
        if !FileManager.default.fileExists(atPath: model.path) {
            FileManager.default.createFile(atPath: model.path, contents: Data())
        }
        return model
    }

    static var assistant: Assistant {
        LlamaAssistant(modelURL: modelURL, engineOverride: engine)
    }

    static let disk = FixtureDisk(state: scenario?.fileVault)
    static let deviceKeys = ProcessMemoryDeviceKeyStore()

    static var hardware: HardwareCapabilities {
        let current = HardwareCapabilities.current()
        guard let memoryGB = scenario?.memoryGB else { return current }
        return HardwareCapabilities(
            isAppleSilicon: current.isAppleSilicon,
            physicalMemoryGB: memoryGB,
            coreCount: current.coreCount,
            chipDescription: current.chipDescription
        )
    }

    /// Settings as a user who finished first run in a chosen folder.
    static func prepare(_ settings: AppSettings) {
        settings.dataRootURL = root
        settings.hasCompletedFirstRun = true
        if !settings.hasAcceptedCurrentLegal { settings.recordLegalAcceptance() }
        if let modelRaw = scenario?.llamaModel, let model = LlamaModel(rawValue: modelRaw) {
            settings.llamaModel = model
        }
        // Only on a run's first launch, so a relaunch keeps what the test changed.
        if isFirstLaunchOfRun {
            settings.appLockEnabled = scenario?.appLockOn ?? false
            if let policy = scenario?.consentPolicy.flatMap(ConsentPolicy.init(rawValue:)) {
                settings.recordingConsentPolicy = policy
            }
            if let length = scenario?.noteLength.flatMap(SummaryVerbosity.init(rawValue:)) {
                settings.summaryVerbosity = length
            }
            if let effort = scenario?.noteEffort.flatMap(AnswerEffort.init(rawValue:)) {
                settings.noteEffort = effort
            }
            if let effort = scenario?.chatEffort.flatMap(AnswerEffort.init(rawValue:)) {
                settings.sessionChatEffort = effort
            }
        }
    }

    /// Builds the scenario's data once per run, before the first window exists.
    @MainActor static func seed(_ model: AppModel) {
        guard isFirstLaunchOfRun else { return }
        sweepStaleRuns()
        defer { FileManager.default.createFile(atPath: seededMarker.path, contents: Data()) }
        guard let store = model.store else { return }
        var firstSessions: [(seed: FixtureScenario.PatientSeed, patient: Patient, session: SessionRecord)] = []
        for seed in scenario?.patients ?? [] {
            guard let patient = try? store.createPatient(name: seed.name) else { continue }
            let hasContent = seed.transcript != nil || seed.myNotes != nil || seed.chat != nil || seed.consentRecorded == true
            var first: SessionRecord?
            for offset in 0..<max(seed.sessions ?? 0, hasContent ? 1 : 0) {
                let made = try? store.createSession(for: patient, on: Date().addingTimeInterval(Double(offset) * 86_400))
                if first == nil { first = made }
            }
            if let first { firstSessions.append((seed, patient, first)) }
        }
        model.refreshPatients()
        for seed in scenario?.patients ?? [] where seed.recordingConsent == true {
            if let patient = model.patients.first(where: { $0.name == seed.name }) {
                model.updatePatient(id: patient.id) { $0.recordingConsentAttestedAt = Date() }
            }
        }
        for (seed, patient, session) in firstSessions {
            if let transcript = seed.transcript { try? store.saveTranscript(transcript, for: patient, session: session) }
            if let notes = seed.myNotes { model.saveNote(sessionID: session.id, text: notes) }
            if let chat = seed.chat {
                let messages = chat.map { ChatMessage(role: ChatRole(rawValue: $0.role) ?? .user, text: $0.text) }
                try? store.saveSessionChat(messages, for: patient, session: session)
            }
            if seed.consentRecorded == true {
                var capture = ConsentCapture()
                capture.confirmed = true
                _ = try? model.recordConsent(capture, patient: patient, session: session)
            }
        }
    }

    /// Removes other runs' folders untouched for a day: a run that crashed or
    /// was stopped never cleans up after itself, and each holds a data folder.
    static func sweepStaleRuns(olderThan age: TimeInterval = 86_400) {
        let parent = root.deletingLastPathComponent()
        let ours: Set<String> = [root.lastPathComponent, support.lastPathComponent]
        let cutoff = Date().addingTimeInterval(-age)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders where !ours.contains(folder.lastPathComponent) {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: folder) }
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

/// FileVault answer: from the scenario in a fixture run, set by the test in the acceptance suite.
final class FixtureDisk: DiskEncryptionProbing {
    enum State: String { case on, off, unknown }
    var state: State

    /// "off", "unknown", or anything else (including nil) for on.
    init(state: String? = nil) { self.state = state.flatMap(State.init(rawValue:)) ?? .on }

    func isDataVolumeEncrypted(_ url: URL) -> Bool? {
        switch state {
        case .on: return true
        case .off: return false
        case .unknown: return nil
        }
    }
}

/// A clock the test moves by hand.
final class FixtureClock {
    private(set) var now: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_767_225_600)) { now = start }
    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// The scenario's scripted model (`ScriptedModel`): its rules answer first,
/// then its replies in order (the last repeats). With a stage time it takes
/// that long over each stage (and over each part it reports reading), so a
/// test can watch the status line move.
final class FixtureScriptedEngine: LocalLLMEngine {
    static let defaultReply = "Fixture reply."

    private let model: ScriptedModel

    init(replies: [String] = [], rules: [FixtureScenario.AIRule] = [], stageMs: Int = 0, parts: Int = 0,
         missing: Bool = false, words: Bool = false) {
        model = ScriptedModel(
            fallback: replies.isEmpty ? [Self.defaultReply] : replies,
            pace: .timed(nanoseconds: 200_000_000), stageMs: stageMs,
            partsForEveryAnswer: parts, streamsWords: words)
        if missing {
            model.add(.init(marker: nil, answer: .fails(LocalLLMEngineError.modelNotDownloaded), once: false))
        }
        for rule in rules {
            model.add(.init(marker: rule.whenPromptContains, answer: .writes(rule.reply), once: false))
        }
    }

    var state: LocalLLMEngineState { model.state }
    var requests: [LocalLLMRequest] { model.requests }
    var requestTexts: [String] { model.requestTexts }

    func load() async throws {}
    func unload() {}
    func generate(_ request: LocalLLMRequest) async throws -> String { try await model.generate(request) }
    func stream(_ request: LocalLLMRequest) -> AsyncThrowingStream<String, Error> { model.stream(request) }
    func stream(
        _ request: LocalLLMRequest, onStats: (@Sendable (AIRunStats) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        model.stream(request, onStats: onStats)
    }
}

/// Transcription that reports a little progress and then waits to be cancelled.
struct FixtureSlowTranscriber: Transcribing {
    var isReady: Bool { true }

    func transcribeSession(
        micURL: URL?, callURL: URL?, onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> String {
        onProgress(TranscriptionProgress(stage: .transcribingMic, fraction: 0.1))
        while true {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
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
    @StateObject private var probe = FixtureProbeFeed()

    var body: some View {
        Color.clear
            .frame(width: 2, height: 2)
            .accessibilityElement()
            .accessibilityIdentifier("fixture-probe")
            // The JSON rides in the label: XCUI reads a label back for any
            // element, but not always a value.
            .accessibilityLabel(probe.json)
            .allowsHitTesting(false)
            .task { await probe.run(appModel: appModel) }
    }
}

/// Keeps the probe's JSON current without loading the main thread: twice a
/// second the files and the store are read on a background task, the
/// transcript's lines are counted (on main, where its layout lives) only when
/// the transcript changed, and the label is republished only when the JSON did.
@MainActor
final class FixtureProbeFeed: ObservableObject {
    @Published private(set) var json = "{}"
    private var transcriptKey: TranscriptKey?
    private var transcriptLines = 0

    private struct TranscriptKey: Equatable {
        let view: ObjectIdentifier
        let text: Int
        let width: CGFloat
    }

    func run(appModel: AppModel) async {
        while !Task.isCancelled {
            await refresh(appModel: appModel)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func refresh(appModel: AppModel) async {
        let store = appModel.store
        let root = FixtureMode.root
        let read = await Task.detached(priority: .utility) {
            (FixtureProbe.files(under: root), FixtureProbe.patientFacts(store: store))
        }.value
        let snapshot = FixtureProbe.Snapshot(
            files: read.0, patients: read.1, aiRequests: FixtureMode.engine.requestTexts,
            transcriptLines: currentTranscriptLines())
        let next = FixtureProbe.encode(snapshot)
        if next != json { json = next }
    }

    private func currentTranscriptLines() -> Int {
        guard let view = FixtureMode.transcriptView else { transcriptKey = nil; return 0 }
        let key = TranscriptKey(view: ObjectIdentifier(view), text: view.string.hashValue,
                                width: view.textContainer?.size.width ?? 0)
        if key != transcriptKey {
            transcriptKey = key
            transcriptLines = FixtureProbe.transcriptLineCount()
        }
        return transcriptLines
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
        /// Lines the transcript on screen is laid out in; 0 when there is none.
        var transcriptLines: Int = 0
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

    /// What the store holds about each patient. Safe off the main thread: the
    /// store's listings also run from App Intents and background work.
    static func patientFacts(store: Store?) -> [PatientFacts] {
        guard let store else { return [] }
        let stored = (try? store.listPatients()) ?? []
        return stored.map { patient -> PatientFacts in
            let dir = store.patientDir(for: patient)
            return PatientFacts(
                name: patient.name, notes: patient.notes, clinicalHistory: patient.clinicalHistory,
                medications: patient.medications.map { "\($0.name) \($0.dose)" },
                folderExists: FileManager.default.fileExists(atPath: dir.path),
                sessions: (try? store.listSessions(for: patient).count) ?? 0,
                consentPolicy: patient.recordingConsentPolicy?.rawValue)
        }
    }

    /// Lines in the laid-out transcript on screen, so a test can tell a turn that wraps
    /// across the pane from one stacked a letter to a line.
    @MainActor static func transcriptLineCount() -> Int {
        guard let view = FixtureMode.transcriptView, let layout = view.layoutManager,
              let container = view.textContainer else { return 0 }
        layout.ensureLayout(for: container)
        var lines = 0
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, _, _ in
            lines += 1
        }
        return lines
    }
}
#endif
