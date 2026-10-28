import CryptoKit
import XCTest
@testable import Aletheia

/// Records every prompt; `stallAfter` makes later calls wait (cancellably).
private final class DigestFakeAssistant: Assistant, @unchecked Sendable {
    var prompts: [String] = []
    var models: [String] = []
    var stallAfter: Int?

    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { [] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String {
        prompts.append(prompt)
        models.append(model)
        if let stallAfter, prompts.count > stallAfter { try await Task.sleep(nanoseconds: 10_000_000_000) }
        return "digest \(prompts.count)"
    }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}

/// A made-up transcript with a line every `step` seconds.
private func transcript(minutes: Int, step: Int = 60, stamp: (Int) -> String = { String(format: "[%02d:%02d]", $0 / 60, $0 % 60) }) -> String {
    stride(from: 0, to: minutes * 60, by: step).map { "\(stamp($0)) You: line at \($0)" }.joined(separator: "\n")
}

final class TranscriptSectionsTests: XCTestCase {
    func testSectionCapUsesEffectiveModelBudget() {
        let system = Prompts.defaultSystemPrompt
        let small = TranscriptSections.maxCharacters(
            for: ContextBudget(tokens: 4_096), systemPrompt: system, clientName: "Jane")
        let normal = TranscriptSections.maxCharacters(
            for: ContextBudget(tokens: 16_384), systemPrompt: system, clientName: "Jane")
        XCTAssertLessThan(small, TranscriptSections.maxCharacters)
        XCTAssertEqual(normal, TranscriptSections.maxCharacters)
        let sections = TranscriptSections.split(String(repeating: "x", count: 20_000), maxCharacters: small)
        XCTAssertTrue(sections.allSatisfy { ContextBudget.weightedLength(of: $0.text) <= small })
    }
    func testSplitsAtTenMinutes() {
        let sections = TranscriptSections.split(transcript(minutes: 25))
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections.map(\.start), [0, 600, 1200])
        XCTAssertEqual(sections.map(\.end), [540, 1140, 1440])
        XCTAssertEqual(sections[1].anchor(index: 1, count: 3), "[10:00–19:00]")
    }

    func testEveryLineIsKeptOnceInOrder() {
        let text = transcript(minutes: 25)
        XCTAssertEqual(TranscriptSections.split(text).map(\.text).joined(separator: "\n"), text)
    }

    func testHourStampsAndAnchors() {
        let text = transcript(minutes: 90, step: 120) { String(format: "[%d:%02d:%02d]", $0 / 3600, ($0 % 3600) / 60, $0 % 60) }
        let sections = TranscriptSections.split(text)
        XCTAssertEqual(sections.count, 9)
        XCTAssertEqual(sections.last?.anchor(index: 8, count: 9), "[1:20:00–1:28:00]")
    }

    func testCharacterCapSplitsDenseSpeech() {
        let line = "[00:01] Call audio: " + String(repeating: "word ", count: 100)
        let text = Array(repeating: line, count: 10).joined(separator: "\n")
        let sections = TranscriptSections.split(text, maxCharacters: 2_000)
        XCTAssertGreaterThan(sections.count, 2)
        XCTAssertTrue(sections.allSatisfy { $0.text.count <= 2_000 })
    }

    func testOverlongSingleLineIsCut() {
        let sections = TranscriptSections.split(String(repeating: "x", count: 5_000), maxCharacters: 2_000)
        XCTAssertEqual(sections.map(\.text.count), [2_000, 2_000, 1_000])
    }

    func testUntimedTranscriptSplitsByCharactersWithPartAnchors() {
        let text = Array(repeating: String(repeating: "a", count: 900), count: 5).joined(separator: "\n")
        let sections = TranscriptSections.split(text, maxCharacters: 2_000)
        XCTAssertEqual(sections.count, 3)
        XCTAssertNil(sections[0].start)
        XCTAssertEqual(sections[1].anchor(index: 1, count: 3), "[part 2 of 3]")
    }

    func testMergedAnchorIsOneFlatRangeEvenWhenMergedAgain() {
        let one = TranscriptSection.mergedAnchor(first: "[00:00–09:00]", last: "[10:00–19:00]")
        XCTAssertEqual(one, "[00:00–19:00]")
        let two = TranscriptSection.mergedAnchor(first: "[20:00–29:00]", last: "[30:00–34:00]")
        XCTAssertEqual(TranscriptSection.mergedAnchor(first: one, last: two), "[00:00–34:00]")
        XCTAssertEqual(
            TranscriptSection.mergedAnchor(first: "[0:50:00–0:59:00]", last: "[1:00:00–1:09:00]"),
            "[0:50:00–1:09:00]"
        )

        let parts = TranscriptSection.mergedAnchor(first: "[part 1 of 5]", last: "[part 2 of 5]")
        XCTAssertEqual(parts, "[part 1–2 of 5]")
        XCTAssertEqual(
            TranscriptSection.mergedAnchor(first: parts, last: "[part 3–4 of 5]"),
            "[part 1–4 of 5]"
        )

        // A timed and an untimed section side by side keep only their two ends.
        let mixed = TranscriptSection.mergedAnchor(first: "[00:00–09:00]", last: "[part 3 of 5]")
        XCTAssertEqual(mixed, "[00:00–09:00] … [part 3 of 5]")
        XCTAssertEqual(TranscriptSection.mergedAnchor(first: mixed, last: "[part 4 of 5]"), "[00:00–09:00] … [part 4 of 5]")
    }

    func testEmptyTranscriptHasNoSections() {
        XCTAssertTrue(TranscriptSections.split(" \n\n").count <= 1)
        XCTAssertTrue(TranscriptSections.split("").isEmpty)
    }
}

final class DigestPromptTests: XCTestCase {
    func testSectionPromptAnchorsLegendAndStrictness() {
        let prompt = Prompts.sectionDigest(text: "[12:30] You: hello", anchor: "[12:30–22:10]")
        XCTAssertTrue(prompt.contains("[12:30–22:10]"))
        XCTAssertTrue(prompt.contains(Prompts.transcriptLegend))
        XCTAssertTrue(prompt.contains("Use only what is in this text"))
        XCTAssertTrue(prompt.contains("Risk: none noted"))
        XCTAssertTrue(prompt.contains("[12:30] Y: hello"))
    }

    func testSessionPromptKeepsEachAnchorAndTheCap() {
        let prompt = Prompts.sessionDigest(sections: [("[0:00–9:00]", "A"), ("[10:00–19:00]", "B")])
        XCTAssertTrue(prompt.contains("[0:00–9:00]\nA"))
        XCTAssertTrue(prompt.contains("[10:00–19:00]\nB"))
        XCTAssertTrue(prompt.contains("2,000"))
        XCTAssertTrue(prompt.contains("Use only what is in the notes"))
    }
}

@MainActor
final class DigestBuilderTests: XCTestCase {
    private func make(_ fake: DigestFakeAssistant) -> (DigestBuilder, AssistantService) {
        (DigestBuilder(queue: InferenceQueue()), AssistantService(assistant: fake, model: "fake-model"))
    }

    func testOneCallPerSectionPlusOneMerge() async throws {
        let fake = DigestFakeAssistant()
        let (builder, service) = make(fake)
        let text = transcript(minutes: 25)
        var seen: [Int] = []
        let digest = try await builder.build(transcript: text, service: service) { section, total in
            XCTAssertEqual(total, 3)
            seen.append(section)
        }
        XCTAssertEqual(fake.prompts.count, 4)
        XCTAssertEqual(seen, [1, 2, 3])
        XCTAssertEqual(Set(fake.models), ["fake-model"])
        XCTAssertEqual(digest.model, "fake-model")
        XCTAssertEqual(digest.promptVersion, Prompts.digestVersion)
        XCTAssertEqual(digest.transcriptFingerprint, NoteFreshness.fingerprint(of: text))
        XCTAssertEqual(digest.sections.map(\.digest), ["digest 1", "digest 2", "digest 3"])
        XCTAssertEqual(digest.sessionDigest, "digest 4")
        XCTAssertTrue(fake.prompts[3].contains("[10:00–19:00]\ndigest 2"))
    }

    func testCancellingStopsFurtherCalls() async throws {
        let fake = DigestFakeAssistant()
        fake.stallAfter = 1
        let (builder, service) = make(fake)
        let text = transcript(minutes: 25)
        let task = Task { try await builder.build(transcript: text, service: service) }
        for _ in 0..<500 where fake.prompts.count < 2 { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(fake.prompts.count, 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fake.prompts.count, 2)
    }

    func testDigestYieldsToANoteWaitingInTheQueue() async throws {
        let queue = InferenceQueue()
        var order: [String] = []
        queue.enqueue(kind: .note, label: "first") { try? await Task.sleep(nanoseconds: 30_000_000); order.append("first") }
        queue.enqueue(kind: .digest, label: "d") { order.append("digest") }
        queue.enqueue(kind: .sessionChat, label: "chat") { order.append("chat") }
        for _ in 0..<500 where order.count < 3 { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(order, ["first", "chat", "digest"])
    }
}

final class DigestStoreTests: XCTestCase {
    private var root: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionDigestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession(_ store: Store, transcript text: String = "[00:01] You: hello") throws -> (Patient, SessionRecord) {
        let patient = try store.createPatient(name: "Dana Cole")
        let session = try store.createSession(for: patient)
        try store.saveTranscript(text, for: patient, session: session)
        return (patient, session)
    }

    private func digest(for text: String, model: String = "m", promptVersion: Int = Prompts.digestVersion) -> SessionDigest {
        SessionDigest(
            model: model, promptVersion: promptVersion, transcriptFingerprint: NoteFreshness.fingerprint(of: text),
            sections: [.init(start: 1, end: 1, digest: "made-up topic")], sessionDigest: "made-up whole", createdAt: Date()
        )
    }

    func testRoundTrip() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        let saved = digest(for: "[00:01] You: hello")
        try store.saveDigest(saved, for: patient, session: session)
        let loaded = try XCTUnwrap(store.digest(for: patient, session: session, model: "m"))
        XCTAssertEqual(loaded.sessionDigest, "made-up whole")
        XCTAssertEqual(loaded.sections, saved.sections)
    }

    func testSealedAtRestAndMigrated() throws {
        let keyed = FileProtector(key: key)
        let store = Store(root: root, protector: keyed)
        let (patient, session) = try makeSession(store)
        try store.saveDigest(digest(for: "[00:01] You: hello"), for: patient, session: session)
        let url = store.sessionDir(for: patient, session: session).appendingPathComponent(Store.digestFileName)
        let bytes = try Data(contentsOf: url)
        XCTAssertTrue(DataCipher.isEnvelope(bytes))
        XCTAssertNil(bytes.range(of: Data("made-up".utf8)))
        XCTAssertNil(Store(root: root).digest(for: patient, session: session, model: "m"), "unreadable without the key")

        XCTAssertTrue(DataMigrator.migrate(root: root, from: keyed, to: .passthrough).isComplete)
        XCTAssertFalse(DataCipher.isEnvelope(try Data(contentsOf: url)))
        XCTAssertTrue(DataMigrator.migrate(root: root, from: .passthrough, to: keyed).isComplete)
        XCTAssertTrue(DataCipher.isEnvelope(try Data(contentsOf: url)))
        XCTAssertNotNil(Store(root: root, protector: keyed).digest(for: patient, session: session, model: "m"))
    }

    func testStaleWhenTranscriptModelOrPromptVersionChanges() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveDigest(digest(for: "[00:01] You: hello"), for: patient, session: session)
        XCTAssertNotNil(store.digest(for: patient, session: session, model: "m"))
        XCTAssertNil(store.digest(for: patient, session: session, model: "other-model"))

        try store.saveDigest(digest(for: "[00:01] You: hello", promptVersion: Prompts.digestVersion - 1), for: patient, session: session)
        XCTAssertNil(store.digest(for: patient, session: session, model: "m"))

        try store.saveDigest(digest(for: "[00:01] You: hello"), for: patient, session: session)
        try store.saveTranscript("[00:01] You: hello again", for: patient, session: session)
        XCTAssertNil(store.digest(for: patient, session: session, model: "m"))
    }

    func testMissingDigestIsNilAndStaysOutOfNotes() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        XCTAssertNil(store.digest(for: patient, session: session, model: "m"))
        XCTAssertFalse(Store.isNoteFileName(Store.digestFileName))
    }

    func testLivesInTheSessionFolderSoItGoesWithTheSession() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveDigest(digest(for: "[00:01] You: hello"), for: patient, session: session)
        let dir = store.sessionDir(for: patient, session: session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("digest.json").path))
        XCTAssertTrue(DataMigrator.sessionFiles(in: dir).contains("digest.json"))
    }
}
