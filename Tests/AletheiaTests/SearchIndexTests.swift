import XCTest
@testable import Aletheia

/// The persistent FTS5 index behind `SessionSearch`. Synthetic text only.
final class SearchIndexTests: XCTestCase {
    private var root: URL!
    private var index: SearchIndex!
    private let calendar = Calendar(identifier: .gregorian)
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 13))! }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        index = SearchIndex(url: root.appendingPathComponent("search.sqlite"))
        SessionSearch.index = index
    }

    override func tearDownWithError() throws {
        SessionSearch.index = SearchIndex()
        try? FileManager.default.removeItem(at: root)
    }

    private func doc(
        _ text: String, kind: SessionSearch.Kind = .transcript, session: UUID? = nil, tag: String = "S1", day: Int = 5
    ) -> SessionSearch.Document {
        .init(date: calendar.date(from: DateComponents(year: 2026, month: 3, day: day))!, tag: tag, kind: kind, text: text,
              session: session, patient: session == nil ? nil : UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    }

    private func search(_ docs: [SessionSearch.Document], _ q: String) -> SessionSearch.Result {
        SessionSearch.search(docs, question: q, now: now, calendar: calendar)
    }

    private func makeStore() throws -> (Store, Patient, SessionRecord) {
        let store = Store(root: root.appendingPathComponent("data"), searchIndex: index)
        let patient = try store.createPatient(name: "Test Person")
        let session = try store.createSession(for: patient)
        return (store, patient, session)
    }

    // MARK: - Sync

    func testSavingATranscriptIndexesItAndAnEditReplacesTheOldVersion() throws {
        let (store, patient, session) = try makeStore()
        try store.saveTranscript("[00:01] A: We talked about the garden.", for: patient, session: session)
        index.flush()
        XCTAssertEqual(index.counts().docs, 1)
        XCTAssertNotNil(index.stamp(session: session.id.uuidString))

        try store.saveTranscript("[00:01] A: We talked about the garden.\n[00:02] A: Then the lake.", for: patient, session: session)
        index.flush()
        XCTAssertEqual(index.counts().docs, 1, "the first version was dropped, not kept beside the new one")
        XCTAssertEqual(index.counts().passages, 2)
    }

    func testSweepIndexesChangedSessionsOnceAndDropsOrphans() throws {
        let (store, patient, session) = try makeStore()
        let other = try store.createSession(for: patient, on: Date(timeIntervalSince1970: 86_400 * 400))
        // Written without the save hook, as an older build or another tool would.
        let plain = Store(root: root.appendingPathComponent("data"))
        try plain.saveTranscript("[00:01] A: Dana called.", for: patient, session: session)
        try plain.saveTranscript("[00:01] A: The lake froze.", for: patient, session: other)
        XCTAssertEqual(index.counts().docs, 0)

        store.syncSearchIndex()
        XCTAssertEqual(index.counts().docs, 2)
        let stamp = index.stamp(session: session.id.uuidString)
        XCTAssertNotNil(stamp)
        store.syncSearchIndex()
        XCTAssertEqual(index.counts().docs, 2, "unchanged transcripts are not indexed again")
        XCTAssertEqual(index.stamp(session: session.id.uuidString), stamp)

        try FileManager.default.removeItem(at: store.sessionDir(for: patient, session: other))
        store.syncSearchIndex()
        XCTAssertEqual(index.counts().docs, 1, "a deleted session's text leaves the index")
        XCTAssertNil(index.stamp(session: other.id.uuidString))
    }

    func testSweepWhileLockedKeepsWhatIsIndexed() throws {
        let dataRoot = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let manager = EncryptionManager(dataRootProvider: { dataRoot })
        try manager.enable(passphrase: "pw", iterations: 1_000)
        let store = Store(root: dataRoot, protector: manager.protector, searchIndex: index)
        let patient = try store.createPatient(name: "Test Person")
        let session = try store.createSession(for: patient)
        try store.saveTranscript("[00:01] A: Dana called.", for: patient, session: session)
        index.flush()
        XCTAssertEqual(index.counts().docs, 1)

        manager.lock()
        let locked = Store(root: dataRoot, protector: manager.protector, searchIndex: index)
        locked.syncSearchIndex()
        XCTAssertEqual(index.counts().docs, 1, "sealed records read as missing, which must not look like deletion")
    }

    func testIndexIsRebuiltWhenItsFileIsDeletedOrCorrupt() throws {
        let (store, patient, session) = try makeStore()
        try store.saveTranscript("[00:01] A: Dana called.\n[00:02] A: The lake froze.", for: patient, session: session)
        index.flush()
        let file = root.appendingPathComponent("search.sqlite")

        index.close()
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(index.counts().docs, 0, "starts empty, no error")
        store.syncSearchIndex()
        XCTAssertEqual(index.counts().docs, 1)

        index.close()
        try Data("this is not a database, just text".utf8).write(to: file)
        XCTAssertEqual(index.counts().docs, 0, "a damaged file is replaced")
        store.syncSearchIndex()
        XCTAssertEqual(index.counts().docs, 1)
        let text = try XCTUnwrap(try store.readTranscript(for: patient, session: session))
        XCTAssertEqual(search([doc(text, session: session.id)], "Dana").totalMentions, 1)
    }

    func testStoredAcrossReopenWithoutReindexing() throws {
        let id = UUID()
        _ = search([doc("[00:01] A: Dana called.", session: id)], "Dana")
        index.close()
        let reopened = SearchIndex(url: root.appendingPathComponent("search.sqlite"))
        XCTAssertEqual(reopened.counts().docs, 1)
        XCTAssertTrue(reopened.missing([SearchIndex.Item(
            session: id.uuidString, patient: nil, kind: "transcript", date: 0,
            fingerprint: SearchIndex.fingerprint(of: "[00:01] A: Dana called."), text: "")]).isEmpty)
    }

    // MARK: - Queries

    func testPhraseAndPrefixAndRanking() {
        let text = [
            "[00:01] A: The wedding cake was lovely.",
            "[00:02] A: A cake for the wedding came later.",
            "[00:03] A: Worrying about work, worried again, worries everywhere.",
            "[00:04] A: Wonderful weather.",
            "[00:05] A: Dana mentioned the cake once.",
        ].joined(separator: "\n")
        let docs = [doc(text)]
        XCTAssertEqual(search(docs, "\"wedding cake\"").hits.map(\.lineIndex), [0])
        let prefix = search(docs, "wor*")
        XCTAssertEqual(prefix.terms.first?.prefix, true)
        XCTAssertEqual(Set(prefix.hits.map(\.lineIndex)), [2], "worrying, work, worried, worries; not wonderful")
        XCTAssertEqual(prefix.totalMentions, 4)
        // bm25: the rarer word wins; a line with both words beats a line with one.
        let ranked = search(docs, "Dana cake").hits
        XCTAssertEqual(ranked.first?.lineIndex, 4)
        XCTAssertEqual(ranked.count, 3)
        XCTAssertGreaterThan(ranked[0].score, ranked[1].score)
    }

    func testHitLocatorMapsOffsetsToLineAndTimestamp() throws {
        let id = UUID()
        let text = "[00:10] A: hello there\n[01:05] B: I told Dana about the lake and Dana laughed.\nno stamp but Dana again\n[02:00] A: bye"
        let result = search([doc(text, session: id)], "Dana")
        XCTAssertEqual(result.totalMentions, 3)
        let first = try XCTUnwrap(result.hits.first { $0.lineIndex == 1 })
        XCTAssertEqual(first.sessionID, id)
        XCTAssertEqual(first.seconds, 65)
        XCTAssertEqual(first.tokenOffsets.count, 2, "both mentions on the line")
        XCTAssertEqual(first.line, "[01:05] B: I told Dana about the lake and Dana laughed.")
        // Offsets index the passage's words (speaker label and time stamp are not part of it).
        XCTAssertEqual(first.tokenOffsets.first, 2)
        let unstamped = try XCTUnwrap(result.hits.first { $0.lineIndex == 2 })
        XCTAssertEqual(unstamped.seconds, 65, "takes the stamp above it")
    }

    func testOnlySearchedDocumentsAreReturnedWhenTheIndexHoldsOthers() {
        _ = search([doc("[00:01] A: Dana called.", session: UUID(), tag: "S9")], "Dana")
        let mine = doc("[00:01] A: Nothing here.", session: UUID())
        XCTAssertEqual(search([mine], "Dana").totalMentions, 0)
    }

    // MARK: - Concurrency

    func testSearchesRunWhileASessionIsBeingReindexed() throws {
        let id = UUID()
        let patient = UUID()
        func text(_ version: Int) -> String {
            (0..<400).map { "[\($0 / 60):\(String(format: "%02d", $0 % 60))] A: line \($0) about Dana and version\(version)" }.joined(separator: "\n")
        }
        let first = text(0)
        _ = search([doc(first, session: id)], "Dana")
        let failures = NSLock()
        var wrong = 0
        let writer = DispatchGroup()
        writer.enter()
        DispatchQueue.global().async {
            for v in 1...20 {
                let t = text(v)
                self.index.replace(
                    session: id.uuidString, patient: patient.uuidString, kinds: [.transcript],
                    items: [SearchIndex.Item(
                        session: id.uuidString, patient: patient.uuidString, kind: "transcript", date: 0,
                        fingerprint: SearchIndex.fingerprint(of: t), text: t)], stamp: "\(v)")
            }
            writer.leave()
        }
        DispatchQueue.concurrentPerform(iterations: 40) { n in
            // Each search carries a complete, consistent version of the document.
            let t = text(n % 21)
            let result = search([doc(t, session: id)], "Dana")
            if result.totalMentions != 400 || result.hits.count != 400 {
                failures.lock(); wrong += 1; failures.unlock()
            }
        }
        writer.wait()
        XCTAssertEqual(wrong, 0)
        XCTAssertEqual(index.counts().docs, 1, "one version is stored for the session")
    }
}
