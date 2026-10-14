import CryptoKit
import SQLite3
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("search.sqlite").path),
                       "the plaintext index does not outlive the unlock")
        index.reopen()   // the app never sweeps behind the lock; this checks the sweep itself is safe
        let locked = Store(root: dataRoot, protector: manager.protector, searchIndex: index)
        locked.syncSearchIndex()
        XCTAssertEqual(index.counts().docs, 0, "sealed records read as missing, which must not look like deletion or leak")
    }

    // MARK: - Locks

    private final class FakeKeys: DeviceKeyStoring {
        var keys: [String: SymmetricKey] = [:]
        func save(_ key: SymmetricKey, for id: String) throws { keys[id] = key }
        func load(for id: String) -> SymmetricKey? { keys[id] }
        func delete(for id: String) { keys[id] = nil }
    }

    private var indexFile: URL { root.appendingPathComponent("search.sqlite") }

    private func populate() {
        let id = UUID()
        _ = search([doc("[00:01] A: Dana called.", session: id)], "Dana")
        XCTAssertTrue(index.isOpen)
    }

    func testIndexStartsClosedWhileEitherLockIsEngaged() {
        var appLocked = true, encryptionLocked = false
        let fresh = SearchIndex(url: root.appendingPathComponent("fresh.sqlite"))
        fresh.mayOpen = { !appLocked && !encryptionLocked }
        XCTAssertTrue(fresh.isBlocked)
        XCTAssertEqual(fresh.counts().docs, 0)
        XCTAssertFalse(fresh.isOpen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fresh.sqlite").path))
        appLocked = false
        XCTAssertFalse(fresh.isBlocked)
        XCTAssertEqual(fresh.counts().docs, 0)
        XCTAssertTrue(fresh.isOpen)
        encryptionLocked = true
        fresh.close()
        XCTAssertTrue(fresh.isBlocked)
    }

    func testUnlockingOneLockDoesNotReopenBehindTheOther() {
        var appLocked = false, encryptionLocked = false
        var kicks = 0
        index.mayOpen = { !appLocked && !encryptionLocked }
        index.onReopen = { kicks += 1 }
        populate()
        appLocked = true; encryptionLocked = true
        index.close()
        appLocked = false
        index.reopen()
        XCTAssertTrue(index.isBlocked)
        XCTAssertEqual(index.counts().docs, 0)
        XCTAssertFalse(index.isOpen, "the encryption lock is still engaged")
        XCTAssertEqual(kicks, 0)
        encryptionLocked = false
        index.reopen()
        XCTAssertFalse(index.isBlocked)
        XCTAssertEqual(index.counts().docs, 1, "an app lock alone keeps the file")
        XCTAssertEqual(kicks, 1, "reopening re-kicks the sweep")
    }

    func testLockMirrorBlocksUntilBothLocksAreReleased() {
        defer { SessionSearch.setAppLocked(false); SessionSearch.setEncryptionLocked(false) }
        index.mayOpen = { SessionSearch.mayOpenIndex }
        SessionSearch.setAppLocked(true); SessionSearch.setEncryptionLocked(true)
        XCTAssertFalse(SessionSearch.mayOpenIndex)
        SessionSearch.setAppLocked(false)
        XCTAssertFalse(SessionSearch.mayOpenIndex)
        XCTAssertEqual(index.counts().docs, 0)
        XCTAssertFalse(index.isOpen)
        SessionSearch.setEncryptionLocked(false)
        XCTAssertTrue(SessionSearch.mayOpenIndex)
        XCTAssertEqual(index.counts().docs, 0)
        XCTAssertTrue(index.isOpen)
    }

    func testEncryptionLockDeletesTheIndexAndRememberedKeyReopensIt() throws {
        let dataRoot = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let keys = FakeKeys()
        let manager = EncryptionManager(dataRootProvider: { dataRoot }, deviceKeys: keys)
        try manager.enable(passphrase: "pw", iterations: 1_000)
        populate()
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexFile.path))

        manager.lock()   // nothing remembered: stays locked
        XCTAssertEqual(manager.state, .lockedNeedsPassphrase)
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexFile.path))
        XCTAssertFalse(index.isOpen)
        XCTAssertEqual(index.counts().docs, 0)
        XCTAssertFalse(index.isOpen, "search stays off while locked")

        try manager.unlock(passphrase: "pw")
        try manager.rememberOnDevice()
        populate()
        manager.lock()   // refresh() re-reads the remembered key and ends unlocked
        XCTAssertEqual(manager.state, .unlocked)
        XCTAssertFalse(index.isBlocked, "an unlocked folder reopens the index")
        XCTAssertEqual(index.counts().docs, 0, "rebuilt empty; the sweep refills it")
    }

    func testDisablingEncryptionDeletesTheIndexAndAppLockAloneKeepsIt() throws {
        let dataRoot = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let manager = EncryptionManager(dataRootProvider: { dataRoot }, deviceKeys: FakeKeys())
        try manager.enable(passphrase: "pw", iterations: 1_000)
        populate()
        SessionSearch.closeIndex()   // the app lock
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexFile.path), "the app lock alone doesn't delete")
        SessionSearch.openIndex()
        XCTAssertEqual(index.counts().docs, 1)
        try manager.disable()
        XCTAssertEqual(index.counts().docs, 0, "deleted, then rebuilt empty")
    }

    // MARK: - Words

    func testCombiningMarksSplitWordsTheSameWayInTheIndexAndTheTokenizer() {
        let word = "ह\u{093F}न\u{094D}द\u{0940}"   // synthetic Hindi word with vowel signs and a virama
        XCTAssertEqual(SessionSearch.tokenize(word), SessionSearch.tokenize("ह न द"))
        let id = UUID()
        let text = "[00:01] A: मैंने \(word) लिखा।"
        XCTAssertEqual(search([doc(text, session: id)], word).totalMentions, 1)
        XCTAssertEqual(search([doc(text, session: id)], "\"\(word)\"").totalMentions, 1)
    }

    func testIndexIsRebuiltWhenItsFileIsDeletedOrCorrupt() throws {
        let (store, patient, session) = try makeStore()
        try store.saveTranscript("[00:01] A: Dana called.\n[00:02] A: The lake froze.", for: patient, session: session)
        index.flush()
        let file = root.appendingPathComponent("search.sqlite")

        index.close(); index.reopen()
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(index.counts().docs, 0, "starts empty, no error")
        store.syncSearchIndex()
        XCTAssertEqual(index.counts().docs, 1)

        index.close(); index.reopen()
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
        XCTAssertLessThanOrEqual(index.counts().docs, 21, "searches never delete versions; only the writer does")
    }

    func testHitsAreCappedButCountsStayExact() {
        let lines = (0..<(SessionSearch.minHitsPerKind + 250)).map { "[00:\(String(format: "%02d", $0 % 60))] A: Dana called \($0)." }
        let result = search([doc(lines.joined(separator: "\n"), session: UUID())], "Dana")
        XCTAssertEqual(result.totalMentions, SessionSearch.minHitsPerKind + 250)
        XCTAssertEqual(result.hits.count, SessionSearch.minHitsPerKind)
        XCTAssertEqual(result.transcriptHitCount, SessionSearch.minHitsPerKind + 250)
        XCTAssertEqual(result.sessionsWithHits, 1)
        XCTAssertFalse(result.hits[0].tokenOffsets.isEmpty, "offsets are filled for the hits that are returned")
    }

    func testLockedIndexDoesNotReopen() {
        let id = UUID()
        _ = search([doc("[00:01] A: Dana called.", session: id)], "Dana")
        index.close()
        XCTAssertFalse(index.isOpen)
        let item = SearchIndex.Item(
            session: id.uuidString, patient: nil, kind: "transcript", date: 0, fingerprint: "x", text: "[00:01] A: Dana called.")
        index.replace(session: id.uuidString, patient: "p", kinds: [.transcript], items: [item], stamp: "1")
        _ = index.stamp(session: id.uuidString)
        index.drop(sessionsNotIn: [])
        XCTAssertEqual(search([doc("[00:01] A: Dana called.", session: id)], "Dana").totalMentions, 0)
        XCTAssertFalse(index.isOpen, "writes, sweeps and searches behind the lock leave it closed")
        index.reopen()
        XCTAssertEqual(search([doc("[00:01] A: Dana called.", session: id)], "Dana").totalMentions, 1)
        XCTAssertTrue(index.isOpen)
    }

    func testOlderSearchDoesNotDeleteNewerSave() {
        let id = UUID()
        let old = doc("[00:01] A: Dana called.", session: id)
        let new = doc("[00:01] A: Dana called twice. Dana.", session: id)
        _ = search([new], "Dana")
        _ = search([old], "Dana")   // a search that started from older text
        XCTAssertEqual(search([new], "Dana").totalMentions, 2)
    }

    func testTypoRanksBelowExactSpelling() {
        let result = search([doc("[00:01] A: Micheal called today.\n[00:02] A: Michael called today.")], "Michael")
        XCTAssertEqual(result.hits.count, 2)
        XCTAssertEqual(result.hits[0].lineIndex, 1, "the exact spelling outranks the typo")
        XCTAssertGreaterThan(result.hits[0].score, result.hits[1].score)
    }

    func testShortPassageBeatsLongOneWithSameCount() {
        let long = "[00:01] A: garden walk with the long quiet river bread coffee window letters winter ladder paper summer story"
        let result = search([doc(long + "\n[00:02] A: garden walk")], "garden")
        XCTAssertEqual(result.hits.first?.lineIndex, 1)
    }

    func testVersionOneFileIsRebuiltNotMisread() throws {
        let file = root.appendingPathComponent("old.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE doc(id INTEGER PRIMARY KEY, fp TEXT); PRAGMA user_version = 1;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        SessionSearch.index = SearchIndex(url: file)
        XCTAssertEqual(search([doc("[00:01] A: Dana called.", session: UUID())], "Dana").totalMentions, 1)
    }

    func testAccentsEmojiAndCRLF() {
        let text = "[00:01] A: José called.\r\n[00:02] A: \u{1F600} happy day\r\n[00:03] A: Jose again"
        let jose = search([doc(text)], "Jose")
        XCTAssertEqual(jose.totalMentions, 2, "José and Jose are one word")
        XCTAssertEqual(Set(jose.hits.map(\.lineIndex)), [0, 2])
        let happy = search([doc(text)], "happy")
        XCTAssertEqual(happy.hits.map(\.lineIndex), [1])
        XCTAssertEqual(happy.hits[0].context.count, 3)
        XCTAssertEqual(happy.hits[0].seconds, 2)
    }

    func testFingerprintHalvesArePadded() {
        XCTAssertEqual(SearchIndex.fingerprint(of: "").count, "0-".count + 32)
    }

    func testLargeBudgetKeepsMoreThanTheMinimumOfHits() {
        let count = SessionSearch.minHitsPerKind + 500
        let text = (0..<count).map { "[00:\(String(format: "%02d", $0 % 60))] A: Dana called \($0)." }.joined(separator: "\n")
        let small = SessionSearch.search([doc(text, session: UUID())], question: "Dana", characterBudget: 6_000, now: now, calendar: calendar)
        let large = SessionSearch.search([doc(text, session: UUID())], question: "Dana", characterBudget: 200_000, now: now, calendar: calendar)
        XCTAssertEqual(small.hits.count, SessionSearch.minHitsPerKind)
        XCTAssertEqual(large.hits.count, count)
        XCTAssertEqual(large.totalMentions, count)
    }

    func testSwappingTheIndexWhileSearchesRun() {
        let first = SearchIndex(url: root.appendingPathComponent("a.sqlite"))
        let second = SearchIndex(url: root.appendingPathComponent("b.sqlite"))
        SessionSearch.index = first
        let docs = [doc("[00:01] A: Dana called.", session: UUID())]
        let done = DispatchGroup()
        for _ in 0..<4 {
            DispatchQueue.global().async(group: done) {
                for _ in 0..<60 { _ = SessionSearch.search(docs, question: "Dana", now: self.now, calendar: self.calendar) }
            }
        }
        for i in 0..<30 { SessionSearch.index = i % 2 == 0 ? second : first }
        done.wait()
        SessionSearch.index = second
        XCTAssertFalse(first.isOpen, "the replaced index is closed")
        // A search that still holds the replaced index finds nothing and doesn't reopen its file.
        XCTAssertNil(first.stamp(session: "x"))
        XCTAssertTrue(first.missing([]).isEmpty)
        XCTAssertFalse(first.isOpen)
    }
}
