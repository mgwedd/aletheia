import CryptoKit
import XCTest
@testable import Aletheia

/// Records every prompt; the section call numbered `failOnSection` (1-based) throws.
private final class SectionCountingAssistant: Assistant, @unchecked Sendable {
    struct Failure: Error {}
    var sectionCalls = 0
    var otherCalls = 0
    var failOnSection: Int?

    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { [] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String {
        if prompt.contains("one section of a therapy session transcript") {
            sectionCalls += 1
            if sectionCalls == failOnSection { throw Failure() }
            return "section summary \(sectionCalls)"
        }
        otherCalls += 1
        return "whole summary"
    }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}

/// A transcript with a line every minute: `minutes / 10` sections, rounded up.
private func transcript(minutes: Int) -> String {
    stride(from: 0, to: minutes * 60, by: 60)
        .map { String(format: "[%02d:%02d] You: line at %d", $0 / 60, $0 % 60, $0) }
        .joined(separator: "\n")
}

final class DigestSchedulePolicyTests: XCTestCase {
    private func date(_ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 3, day: day))!
    }

    // MARK: When to run, when to pause

    func testNothingGoingOnRuns() {
        XCTAssertNil(DigestSchedulePolicy.pauseReason(DigestActivity()))
    }

    func testOtherWorkAlwaysComesFirst() {
        XCTAssertEqual(DigestSchedulePolicy.pauseReason(DigestActivity(locked: true, recording: true)), .locked)
        XCTAssertEqual(DigestSchedulePolicy.pauseReason(DigestActivity(recording: true, modelBusy: true)), .recording)
        XCTAssertEqual(DigestSchedulePolicy.pauseReason(DigestActivity(transcribing: true)), .transcribing)
        XCTAssertEqual(DigestSchedulePolicy.pauseReason(DigestActivity(modelBusy: true)), .modelBusy)
        // "Prepare now" never runs alongside a recording, a transcription, other AI work or the lock.
        for busy in [DigestActivity(locked: true), DigestActivity(recording: true), DigestActivity(transcribing: true), DigestActivity(modelBusy: true)] {
            var now = busy
            now.preparingNow = true
            XCTAssertNotNil(DigestSchedulePolicy.pauseReason(now))
            XCTAssertFalse(DigestSchedulePolicy.pauseReason(now)!.canPrepareNow)
        }
    }

    func testConservativeDefaultsPauseAndPrepareNowOverridesThem() {
        XCTAssertEqual(DigestSchedulePolicy.pauseReason(DigestActivity(userPaused: true, onBattery: true)), .user)
        XCTAssertEqual(DigestSchedulePolicy.pauseReason(DigestActivity(lowPowerMode: true, onBattery: true)), .lowPowerMode)
        XCTAssertEqual(DigestSchedulePolicy.pauseReason(DigestActivity(onBattery: true)), .battery)
        XCTAssertEqual(DigestSchedulePolicy.pauseReason(DigestActivity(recentFailure: true)), .failure)
        let all = DigestActivity(userPaused: true, lowPowerMode: true, onBattery: true, recentFailure: true, preparingNow: true)
        XCTAssertNil(DigestSchedulePolicy.pauseReason(all))
    }

    func testLowPowerModePausesWithoutBatteryAndStatusStaysAccurate() {
        XCTAssertEqual(DigestSchedulePolicy.pauseReason(DigestActivity(lowPowerMode: true, onBattery: false)), .lowPowerMode)
        XCTAssertNil(DigestSchedulePolicy.pauseReason(DigestActivity(onBattery: false)))
        XCTAssertEqual(DigestPauseReason.battery.text, "paused on battery")
        XCTAssertEqual(DigestPauseReason.lowPowerMode.text, "paused in Low Power Mode")
    }

    // MARK: Which sessions need a summary

    func testOnlySessionsThatCannotBeReadWholeNeedASummary() {
        // Short session, short history: read whole everywhere.
        XCTAssertFalse(DigestSchedulePolicy.needsSummary(transcriptCharacters: 5_000, historyCharacters: 20_000, room: 30_000))
        // The session alone is too long for one prompt.
        XCTAssertTrue(DigestSchedulePolicy.needsSummary(transcriptCharacters: 40_000, historyCharacters: 40_000, room: 30_000))
        // Short session, but the patient's history no longer fits.
        XCTAssertTrue(DigestSchedulePolicy.needsSummary(transcriptCharacters: 5_000, historyCharacters: 90_000, room: 30_000))
        XCTAssertFalse(DigestSchedulePolicy.needsSummary(transcriptCharacters: 0, historyCharacters: 90_000, room: 30_000))
    }

    func testOpenSessionThenPatientThenNewestFirst() {
        let a = UUID(), b = UUID()
        let old = DigestSchedulePolicy.Candidate(patientID: a, sessionID: UUID(), date: date(1))
        let new = DigestSchedulePolicy.Candidate(patientID: a, sessionID: UUID(), date: date(20))
        let other = DigestSchedulePolicy.Candidate(patientID: b, sessionID: UUID(), date: date(25))
        let open = DigestSchedulePolicy.Candidate(patientID: b, sessionID: UUID(), date: date(2))

        XCTAssertEqual(DigestSchedulePolicy.order([old, new, other, open], session: nil, patient: nil), [other, new, open, old])
        XCTAssertEqual(DigestSchedulePolicy.order([old, new, other, open], session: nil, patient: a), [new, old, other, open])
        XCTAssertEqual(DigestSchedulePolicy.order([old, new, other, open], session: open.sessionID, patient: a), [open, new, old, other])
    }

    // MARK: What the status says

    func testStatusLineAndItsControl() {
        XCTAssertNil(DigestSchedulePolicy.status(ready: 0, needed: 0, pause: nil, building: false), "nothing needs a summary")
        XCTAssertEqual(DigestSchedulePolicy.status(ready: 100, needed: 100, pause: .battery, building: false)?.text, "Summaries: all 100 ready")
        XCTAssertNil(DigestSchedulePolicy.status(ready: 100, needed: 100, pause: nil, building: false)?.action)

        let building = DigestSchedulePolicy.status(ready: 62, needed: 100, pause: nil, building: true)
        XCTAssertEqual(building?.text, "Summaries: 62 of 100 ready · preparing")
        XCTAssertEqual(building?.action, .pause)

        let user = DigestSchedulePolicy.status(ready: 62, needed: 100, pause: .user, building: false)
        XCTAssertEqual(user?.text, "Summaries: 62 of 100 ready · paused")
        XCTAssertEqual(user?.action, .resume)

        let battery = DigestSchedulePolicy.status(ready: 62, needed: 100, pause: .battery, building: false)
        XCTAssertEqual(battery?.text, "Summaries: 62 of 100 ready · paused on battery")
        XCTAssertEqual(battery?.action, .prepareNow)

        let recording = DigestSchedulePolicy.status(ready: 62, needed: 100, pause: .recording, building: false)
        XCTAssertEqual(recording?.text, "Summaries: 62 of 100 ready · paused while recording")
        XCTAssertEqual(recording?.action, .pause)
    }

    func testSectionKeyChangesWithEverythingThatShapesThePrompt() {
        let key = DigestSchedulePolicy.sectionKey(text: "a", anchor: "[0:00–9:00]", model: "m", promptVersion: 3)
        XCTAssertEqual(key, DigestSchedulePolicy.sectionKey(text: "a", anchor: "[0:00–9:00]", model: "m", promptVersion: 3))
        XCTAssertNotEqual(key, DigestSchedulePolicy.sectionKey(text: "b", anchor: "[0:00–9:00]", model: "m", promptVersion: 3))
        XCTAssertNotEqual(key, DigestSchedulePolicy.sectionKey(text: "a", anchor: "[10:00–19:00]", model: "m", promptVersion: 3))
        XCTAssertNotEqual(key, DigestSchedulePolicy.sectionKey(text: "a", anchor: "[0:00–9:00]", model: "n", promptVersion: 3))
        XCTAssertNotEqual(key, DigestSchedulePolicy.sectionKey(text: "a", anchor: "[0:00–9:00]", model: "m", promptVersion: 4))
    }
}

@MainActor
final class DigestResumeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DigestResume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A build that fails part-way keeps the sections it finished; the next
    /// build asks the model only for the rest.
    func testAFailedBuildResumesFromTheSectionsItFinished() async throws {
        let text = transcript(minutes: 30)   // 3 sections
        let stub = SectionCountingAssistant()
        stub.failOnSection = 3
        let service = AssistantService(assistant: stub, model: "m")
        let builder = DigestBuilder(queue: InferenceQueue())
        var saved: [String: String] = [:]

        let first = SectionDigestCache(entries: [:]) { saved = $0 }
        do {
            _ = try await builder.build(transcript: text, service: service, inline: true, cache: first)
            XCTFail("the third section fails")
        } catch {}
        XCTAssertEqual(saved.count, 2, "the two finished sections were kept as they were written")

        stub.sectionCalls = 0
        stub.failOnSection = nil
        let second = SectionDigestCache(entries: saved) { saved = $0 }
        let digest = try await builder.build(transcript: text, service: service, inline: true, cache: second)
        XCTAssertEqual(stub.sectionCalls, 1, "only the section that failed is asked for again")
        XCTAssertEqual(digest.sections.count, 3)
        XCTAssertEqual(digest.sections.map(\.digest), ["section summary 1", "section summary 2", "section summary 1"])

        // A different model is a miss: nothing is reused.
        stub.sectionCalls = 0
        let other = AssistantService(assistant: stub, model: "other")
        _ = try await builder.build(transcript: text, service: other, inline: true, cache: SectionDigestCache(entries: saved) { _ in })
        XCTAssertEqual(stub.sectionCalls, 3)
    }

    func testPruneKeepsOnlyTheSectionsOfTheTranscriptBuilt() {
        var saved: [String: String] = [:]
        let cache = SectionDigestCache(entries: ["old": "x", "kept": "y"]) { saved = $0 }
        XCTAssertEqual(cache.lookup("kept"), "y")
        cache.store("new", "z")
        cache.prune()
        XCTAssertEqual(saved, ["kept": "y", "new": "z"])
    }

    func testSectionCacheIsSealedAtRestAndMigratedWithTheSession() throws {
        let key = SymmetricKey(size: .bits256)
        let keyed = FileProtector(key: key)
        let store = Store(root: root, protector: keyed)
        let patient = try store.createPatient(name: "Dana Cole")
        let session = try store.createSession(for: patient)
        try store.saveSectionDigestCache(["k": "Client named her sister"], for: patient, session: session)
        XCTAssertEqual(store.sectionDigestCache(for: patient, session: session), ["k": "Client named her sister"])

        let url = store.sessionDir(for: patient, session: session).appendingPathComponent(Store.digestSectionsFileName)
        XCTAssertTrue(DataCipher.isEnvelope(try Data(contentsOf: url)))
        XCTAssertTrue(DataMigrator.sessionFiles(in: url.deletingLastPathComponent()).contains(Store.digestSectionsFileName))
        XCTAssertEqual(Store(root: root).sectionDigestCache(for: patient, session: session), [:], "unreadable without the key")
    }

    // MARK: Which sessions the scan picks

    func testScanFindsOnlySessionsThatNeedASummaryAndCountsTheReadyOnes() throws {
        let store = Store(root: root)
        let short = try store.createPatient(name: "Short History")
        for day in 1...3 {
            let s = try store.createSession(for: short, on: Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 1, day: day))!)
            try store.saveTranscript(transcript(minutes: 5), for: short, session: s)
        }
        let long = try store.createPatient(name: "Long History")
        var sessions: [SessionRecord] = []
        for day in 1...4 {
            let s = try store.createSession(for: long, on: Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 2, day: day))!)
            try store.saveTranscript(transcript(minutes: 50), for: long, session: s)
            sessions.append(s)
        }
        let done = transcript(minutes: 50)
        try store.saveDigest(SessionDigest(
            model: "any", promptVersion: Prompts.digestVersion, transcriptFingerprint: NoteFreshness.fingerprint(of: done),
            sections: [], sessionDigest: "s", createdAt: Date()
        ), for: long, session: sessions[0])

        // Each 50-minute transcript is about 1,250 characters; the long history (~5,000) is over this room.
        let room = 4_000
        let result = DigestScheduler.scanSessions(store: store, patients: [short, long], room: room)

        XCTAssertNil(result.counts[short.id], "a history that fits needs no summaries")
        XCTAssertEqual(result.counts[long.id], DigestScheduler.Count(ready: 1, needed: 4), "a summary from any model counts as ready")
        XCTAssertEqual(Set(result.work.map(\.sessionID)), Set(sessions.dropFirst().map(\.id)))
    }

    // MARK: Pausing

    func testItPausesWhileRecordingAndShowsWhy() {
        let settings = AppSettings.shared
        let wasPaused = settings.summariesPaused
        defer { settings.summariesPaused = wasPaused }
        settings.summariesPaused = false

        let queue = InferenceQueue()
        let scheduler = DigestScheduler(builder: DigestBuilder(queue: queue), queue: queue, settings: settings)
        var recording = true
        scheduler.attach(context: { nil }, activity: { DigestActivity(recording: recording) })
        defer { scheduler.stop() }

        scheduler.evaluate()
        XCTAssertEqual(scheduler.pauseReason, .recording)
        recording = false
        scheduler.evaluate()
        XCTAssertNil(scheduler.pauseReason)

        scheduler.perform(.pause, patientID: UUID())
        XCTAssertTrue(settings.summariesPaused)
        XCTAssertEqual(scheduler.pauseReason, .user)
        scheduler.perform(.prepareNow, patientID: UUID())
        XCTAssertNil(scheduler.pauseReason, "Prepare now runs despite the user's pause")
        XCTAssertTrue(scheduler.preparingNow)
    }

    func testPrepareSummariesOnBatterySettingLiftsOnlyTheBatteryPause() {
        let settings = AppSettings.shared
        let wasPaused = settings.summariesPaused
        let wasOnBattery = settings.prepareSummariesOnBattery
        defer {
            settings.summariesPaused = wasPaused
            settings.prepareSummariesOnBattery = wasOnBattery
        }
        settings.summariesPaused = false
        settings.prepareSummariesOnBattery = false

        let queue = InferenceQueue()
        let scheduler = DigestScheduler(builder: DigestBuilder(queue: queue), queue: queue, settings: settings)
        var lowPower = false
        scheduler.attach(context: { nil }, activity: { DigestActivity(lowPowerMode: lowPower, onBattery: true) })
        defer { scheduler.stop() }

        scheduler.evaluate()
        XCTAssertEqual(scheduler.pauseReason, .battery, "off: battery pauses")
        settings.prepareSummariesOnBattery = true
        scheduler.evaluate()
        XCTAssertNil(scheduler.pauseReason, "on: battery no longer pauses")
        lowPower = true
        scheduler.evaluate()
        XCTAssertEqual(scheduler.pauseReason, .lowPowerMode, "on: Low Power Mode still pauses")
        lowPower = false
        settings.prepareSummariesOnBattery = false
        scheduler.evaluate()
        XCTAssertEqual(scheduler.pauseReason, .battery, "turned off again: battery pauses")
    }

    func testPrepareSummariesOnBatterySettingPersists() {
        let settings = AppSettings.shared
        let original = settings.prepareSummariesOnBattery
        defer { settings.prepareSummariesOnBattery = original }

        settings.prepareSummariesOnBattery = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "prepareSummariesOnBattery"))
        settings.prepareSummariesOnBattery = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "prepareSummariesOnBattery"))
    }
}
