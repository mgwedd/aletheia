import SQLite3
import XCTest
@testable import Aletheia

/// Global search through the real index: what it covers, that it shows only
/// current text, that saves and deletes reach it without a sweep, what it
/// reads per query, and how it says results may be incomplete. Synthetic text.
final class GlobalSearchIndexTests: XCTestCase {
    private var root: URL!
    private var index: SearchIndex!
    private var comments: CommentStore!
    private var store: Store!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlobalSearchIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        index = SearchIndex(url: root.appendingPathComponent("search.sqlite"))
        comments = try XCTUnwrap(CommentStore(root: root))
        store = Store(root: root, commentStore: comments, searchIndex: index)
    }

    override func tearDownWithError() throws {
        index.flush()
        SessionSearch.index = SearchIndex()
        try? FileManager.default.removeItem(at: root)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    /// Waits for queued index writes, then searches.
    private func search(_ query: String, limits: GlobalSearchLimits = GlobalSearchLimits()) -> GlobalSearchResults {
        index.flush()
        return store.globalSearch(query: query, limits: limits, calendar: calendar)
    }

    /// A store without the index, writing as an older build or another tool would.
    private var plain: Store { Store(root: root, commentStore: comments) }

    // MARK: Coverage of every kind

    func testEverySourceIsFoundThroughTheIndex() throws {
        let patient = try store.createPatient(name: "Sam Doe")
        let session = try store.createSession(for: patient, on: date(2026, 10, 8))
        try store.saveTranscript("[00:57] You: We have been thinking about couples therapy.", for: patient, session: session)
        try store.saveNote("Presenting topics: couples therapy.", for: patient, session: session, format: .soap)
        XCTAssertTrue(comments.saveNote(sessionID: session.id, text: "Discussed couples therapy vs individual."))
        XCTAssertNotNil(comments.addComment(sessionID: session.id, quotedText: "thinking about it", body: "Raise couples therapy referrals.", anchorSeconds: 57))
        store.syncSearchIndex()

        let results = search("couples therapy")
        XCTAssertEqual(results.coverage, .complete)
        XCTAssertEqual(results.sections.map(\.kind), [.sessionNotes, .note, .comment, .transcript])
        XCTAssertTrue(results.sections.allSatisfy { $0.total == 1 })
        let day = SearchHit.dateText(session.date)
        XCTAssertEqual(results.section(.note)?.hits.first?.title, "Sam Doe, \(day) (SOAP)")
        XCTAssertEqual(results.section(.note)?.hits.first?.noteFormat, .soap)
        XCTAssertEqual(results.section(.comment)?.hits.first?.title, "Sam Doe, \(day) at 0:57")
        XCTAssertNotNil(results.section(.comment)?.hits.first?.commentID)
        XCTAssertEqual(results.section(.transcript)?.hits.first?.snippet, "[00:57] You: We have been thinking about couples therapy.")
        XCTAssertTrue(results.hits.allSatisfy { $0.session?.id == session.id })
        XCTAssertTrue(results.hits.allSatisfy { $0.snippet.localizedCaseInsensitiveContains("couples") })
    }

    /// A transcript or note hit carries the passage it showed, and opening it
    /// at that passage flashes the match there, not an earlier mention.
    func testHitsCarryThePassageToOpenAt() throws {
        let patient = try store.createPatient(name: "Sam Doe")
        let session = try store.createSession(for: patient, on: date(2026, 10, 8))
        let transcript = "[00:01] You: How was the week?\n[00:05] Client: Fine.\n[00:09] Client: The insomnia came back, the insomnia is worse."
        try store.saveTranscript(transcript, for: patient, session: session)
        try store.saveNote("Opening check-in.\n\nReports insomnia returning.", for: patient, session: session, format: .soap)
        store.syncSearchIndex()

        let results = search("insomnia")
        let hit = try XCTUnwrap(results.section(.transcript)?.hits.first)
        XCTAssertEqual(hit.passage, 2)
        let focus = try XCTUnwrap(SearchHitDestination(hit).searchFocus(query: "insomnia"))
        let range = try XCTUnwrap(focus.transcriptRange(in: transcript))
        XCTAssertEqual(range, (transcript as NSString).range(of: "insomnia"))
        XCTAssertEqual(results.section(.note)?.hits.first?.passage, 1)
    }

    func testPatientsByNameAndSessionsByDate() throws {
        let jane = try store.createPatient(name: "Jane Doe")
        let bob = try store.createPatient(name: "Bob Lee")
        let october = try store.createSession(for: jane, on: date(2026, 10, 8))
        _ = try store.createSession(for: jane, on: date(2026, 3, 3))
        let bobs = try store.createSession(for: bob, on: date(2026, 10, 8))
        store.syncSearchIndex()

        let byName = search("jane")
        XCTAssertEqual(byName.sections.map(\.kind), [.patient])
        XCTAssertEqual(byName.section(.patient)?.hits.first?.snippet, "2 sessions")
        XCTAssertNil(byName.section(.patient)?.hits.first?.session)

        let byDate = search("oct 8")
        XCTAssertEqual(byDate.section(.session)?.hits.compactMap(\.session?.id), [bobs.id, october.id], "same day: by patient name")
        XCTAssertEqual(search("jane october").section(.session)?.hits.compactMap(\.session?.id), [october.id])
        XCTAssertNil(search("jane october").section(.patient), "a patient needs every word in the name")
    }

    func testWordsCanBeAnsweredByTheNameOrTheDate() throws {
        let jane = try store.createPatient(name: "Jane Doe")
        let bob = try store.createPatient(name: "Bob Lee")
        let janes = try store.createSession(for: jane, on: date(2026, 10, 8))
        let bobs = try store.createSession(for: bob, on: date(2026, 3, 3))
        try store.saveTranscript("[00:01] You: Insomnia again this week.", for: jane, session: janes)
        try store.saveTranscript("[00:01] You: Insomnia since the move.", for: bob, session: bobs)
        store.syncSearchIndex()

        XCTAssertEqual(search("insomnia").section(.transcript)?.total, 2)
        XCTAssertEqual(search("jane insomnia").section(.transcript)?.hits.compactMap(\.session?.id), [janes.id])
        XCTAssertEqual(search("insomnia march 2026").section(.transcript)?.hits.compactMap(\.session?.id), [bobs.id])
        XCTAssertEqual(search("insomnia march").section(.transcript)?.total ?? 0, 0, "march alone is a word, not a date (#354)")
        XCTAssertNil(search("jane").section(.transcript), "a word only the name answers is not a text match")
    }

    func testEveryWordMustBeInOnePlaceButNotOneLine() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let first = try store.createSession(for: patient, on: date(2026, 1, 5))
        let second = try store.createSession(for: patient, on: date(2026, 1, 12))
        try store.saveTranscript("[00:01] You: Couples came up.\n[00:02] You: Later, therapy too.", for: patient, session: first)
        try store.saveTranscript("[00:01] You: Couples only.", for: patient, session: second)
        try store.saveNote("Therapy was discussed.", for: patient, session: second, format: .narrative)
        store.syncSearchIndex()

        let results = search("couples therapy")
        XCTAssertEqual(results.section(.transcript)?.hits.compactMap(\.session?.id), [first.id])
        let snippet = try XCTUnwrap(results.section(.transcript)?.hits.first?.snippet)
        XCTAssertTrue(["[00:01] You: Couples came up.", "[00:02] You: Later, therapy too."].contains(snippet), snippet)
        XCTAssertNil(results.section(.note), "the second session has the words in two different places")
    }

    func testInflectedAndPartlyTypedWordsMatch() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        try store.saveTranscript("[00:01] You: She worried about therapy.", for: patient, session: session)
        store.syncSearchIndex()
        XCTAssertEqual(search("worries").section(.transcript)?.total, 1)
        XCTAssertEqual(search("thera").section(.transcript)?.total, 1)
        XCTAssertNil(search("therapist").section(.transcript), "a common word is not searched")
        XCTAssertEqual(search("the").unsearchedWords, ["the"])
    }

    func testHeadingsTheIndexStoresDoNotMatchOnTheirOwn() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        try store.saveNote("Client reports better sleep.", for: patient, session: session, format: .soap)
        XCTAssertTrue(comments.saveNote(sessionID: session.id, text: "Better sleep."))
        XCTAssertNotNil(comments.addComment(sessionID: session.id, quotedText: "", body: "Sleep is better."))
        store.syncSearchIndex()

        XCTAssertEqual(search("sleep").sections.map(\.kind), [.sessionNotes, .note, .comment])
        for heading in ["generated progress", "soap", "margin", "notes"] {
            XCTAssertTrue(search(heading).sections.isEmpty, heading)
        }
    }

    func testResolvedCommentsAreFound() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        let comment = try XCTUnwrap(comments.addComment(sessionID: session.id, quotedText: "", body: "Check the sertraline dose."))
        XCTAssertTrue(comments.setCommentResolved(id: comment.id, resolved: true))
        store.syncSearchIndex()
        XCTAssertEqual(search("sertraline").section(.comment)?.hits.first?.commentID, comment.id)
    }

    // MARK: Only current text

    func testVersionsAChatSearchStoredAreNotShown() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        try store.saveTranscript("[00:01] You: The garden.", for: patient, session: session)
        store.syncSearchIndex()
        // A patient-chat search handed text that isn't what's saved (an older or unsaved version).
        SessionSearch.index = index
        let other = SessionSearch.Document(
            date: session.date, tag: "S1", kind: .transcript, text: "[00:01] You: The lake froze.", session: session.id, patient: patient.id)
        XCTAssertEqual(SessionSearch.search([other], question: "lake").totalMentions, 1)

        let results = search("lake")
        XCTAssertTrue(results.sections.isEmpty)
        XCTAssertEqual(results.coverage, .complete, "nothing stale was even looked at")
        XCTAssertEqual(search("garden").section(.transcript)?.total, 1)
    }

    func testMatchLiveReadsOnlyLiveDocumentsAndCanStop() throws {
        let item = SearchIndex.Item(
            session: "s1", patient: "p", kind: "transcript", date: 0,
            fingerprint: SearchIndex.fingerprint(of: "[00:01] A: The garden."), text: "[00:01] A: The garden.")
        index.replace(session: "s1", patient: "p", kinds: [.transcript], items: [item], stamp: "1")
        SessionSearch.index = index
        _ = SessionSearch.search([.init(date: Date(), tag: "S1", kind: .transcript, text: "[00:01] A: Garden two.", session: UUID())], question: "garden")
        XCTAssertEqual(index.counts().docs, 2)

        guard case .found(let documents, let passages) = index.matchLive(clauses: ["\"garden\" *"]) else {
            return XCTFail("the index is readable")
        }
        XCTAssertEqual(documents.values.map(\.session), ["s1"])
        XCTAssertEqual(passages.count, 1)
        XCTAssertEqual(passages[0].count, 1)
        XCTAssertGreaterThan(passages[0][0].score, 0)

        guard case .cancelled = index.matchLive(clauses: ["\"garden\" *"], shouldContinue: { false }) else {
            return XCTFail("stops when told to")
        }
        index.mayOpen = { false }
        index.close()
        guard case .unavailable = index.matchLive(clauses: ["\"garden\" *"]) else {
            return XCTFail("a locked index can't be read")
        }
    }

    func testATranscriptChangedSinceIndexingIsReadAsItIsNow() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        try store.saveTranscript("[00:01] You: The garden.", for: patient, session: session)
        store.syncSearchIndex()
        index.flush()

        // Edited behind the index's back (another tool): the line moved.
        try plain.saveTranscript("[00:01] You: Moved.\n[00:02] You: The garden.", for: patient, session: session)
        let moved = search("garden")
        XCTAssertEqual(moved.section(.transcript)?.hits.first?.snippet, "[00:02] You: The garden.")
        XCTAssertEqual(moved.coverage, .indexing(sessions: 1))

        // And now the word is gone: not shown, and said to be incomplete.
        try plain.saveTranscript("[00:01] You: Only the lake.", for: patient, session: session)
        let gone = search("garden")
        XCTAssertNil(gone.section(.transcript))
        XCTAssertEqual(gone.coverage, .indexing(sessions: 1))
    }

    // MARK: Saves and deletes reach the index without a sweep

    func testSavesAreSearchableWithoutASweep() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        store.syncSearchIndex()

        try store.saveTranscript("[00:01] You: Swimming helped.", for: patient, session: session)
        XCTAssertEqual(search("swimming").section(.transcript)?.total, 1)
        try store.saveTranscript("[00:01] You: Cycling now.", for: patient, session: session)
        XCTAssertNil(search("swimming").section(.transcript), "the old transcript is gone")

        try store.saveEditedNote("Planned cycling.", for: patient, session: session, format: .dap)
        XCTAssertEqual(search("planned").section(.note)?.hits.first?.noteFormat, .dap)

        XCTAssertTrue(comments.saveNote(sessionID: session.id, text: "Hike on Sunday."))
        XCTAssertEqual(search("hike").section(.sessionNotes)?.total, 1)

        let comment = try XCTUnwrap(comments.addComment(sessionID: session.id, quotedText: "", body: "Ask about kayaking."))
        XCTAssertEqual(search("kayaking").section(.comment)?.total, 1)
        XCTAssertTrue(comments.updateComment(id: comment.id, body: "Ask about rowing."))
        XCTAssertNil(search("kayaking").section(.comment))
        XCTAssertEqual(search("rowing").section(.comment)?.total, 1)
        XCTAssertTrue(comments.deleteComment(id: comment.id))
        XCTAssertNil(search("rowing").section(.comment))
        XCTAssertEqual(search("rowing").coverage, .complete)
    }

    func testCommentStoreReportsTheSessionOfEveryChange() throws {
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let annotations = try XCTUnwrap(CommentStore(root: other))
        var reported: [UUID] = []
        annotations.onSessionAnnotationsChanged = { reported.append($0) }
        let session = UUID()
        let comment = try XCTUnwrap(annotations.addComment(sessionID: session, quotedText: "", body: "a"))
        XCTAssertTrue(annotations.updateComment(id: comment.id, body: "b"))
        XCTAssertTrue(annotations.setCommentResolved(id: comment.id, resolved: true))
        XCTAssertTrue(annotations.saveNote(sessionID: session, text: "n"))
        XCTAssertTrue(annotations.deleteComment(id: comment.id))
        XCTAssertFalse(annotations.updateComment(id: "missing", body: "c"))
        XCTAssertEqual(reported, Array(repeating: session, count: 5))
    }

    func testDeletingAPatientRemovesItsResults() throws {
        let jane = try store.createPatient(name: "Jane Doe")
        let bob = try store.createPatient(name: "Bob Lee")
        let janes = try store.createSession(for: jane)
        let bobs = try store.createSession(for: bob)
        try store.saveTranscript("[00:01] You: The garden.", for: jane, session: janes)
        try store.saveTranscript("[00:01] You: The garden.", for: bob, session: bobs)
        store.syncSearchIndex()
        XCTAssertEqual(search("garden").section(.transcript)?.total, 2)

        try store.deletePatient(jane)
        let after = search("garden")
        XCTAssertEqual(after.section(.transcript)?.hits.map(\.patient.id), [bob.id])
        XCTAssertNil(search("jane").section(.patient))
        XCTAssertEqual(after.coverage, .complete)
    }

    func testDeletingAPatientAlsoDropsASaveStillQueuedForTheIndex() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        store.syncSearchIndex()
        index.flush()
        let hold = DispatchSemaphore(value: 0)
        index.async { hold.wait() }   // the index is busy: the save below waits its turn
        try store.saveTranscript("[00:01] You: The garden.", for: patient, session: session)
        try store.deletePatient(patient)
        hold.signal()
        index.flush()
        XCTAssertEqual(index.counts().docs, 0, "the queued save ran after the delete; the second purge removed it")
        XCTAssertNil(index.stamp(session: session.id.uuidString))
    }

    func testASessionWhoseFolderIsGoneIsNotShown() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        try store.saveTranscript("[00:01] You: The garden.", for: patient, session: session)
        store.syncSearchIndex()
        try FileManager.default.removeItem(at: store.sessionDir(for: patient, session: session))
        XCTAssertNil(search("garden").section(.transcript), "before any sweep drops its rows")
    }

    // MARK: Honest coverage

    func testResultsSayTheyMayBeIncompleteUntilEverySessionIsIndexed() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        for day in 1...3 {
            let session = try store.createSession(for: patient, on: date(2026, 2, day))
            try plain.saveTranscript("[00:01] You: The garden, day \(day).", for: patient, session: session)
        }
        XCTAssertEqual(search("garden").coverage, .checking, "nothing has compared the index with the folder yet")

        index.progress.beginChecking()
        let plan = try XCTUnwrap(store.searchIndexPlan())
        XCTAssertEqual(plan.staleSessions.count, 3)
        index.progress.checked(stale: plan.staleSessions)
        XCTAssertTrue(store.indexSearchTarget(plan.targets[0]))
        index.progress.indexed(session: plan.targets[0].session.id.uuidString)

        let partial = search("garden")
        XCTAssertEqual(partial.section(.transcript)?.total, 1)
        XCTAssertEqual(partial.coverage, .indexing(sessions: 2))
        XCTAssertEqual(partial.coverage.statusText, "Indexing 2 sessions; results may be incomplete.")

        store.syncSearchIndex()
        let whole = search("garden")
        XCTAssertEqual(whole.section(.transcript)?.total, 3)
        XCTAssertEqual(whole.coverage, .complete)
    }

    func testFallsBackToReadingFilesWhenTheIndexCannotBeRead() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        try store.saveTranscript("[00:01] You: The garden.", for: patient, session: session)
        index.flush()
        index.mayOpen = { false }
        index.close()
        let results = search("garden")
        XCTAssertEqual(results.coverage, .scanned)
        XCTAssertEqual(results.section(.transcript)?.total, 1)

        let withoutIndex = Store(root: root, commentStore: comments).globalSearch(query: "garden", calendar: calendar)
        XCTAssertEqual(withoutIndex.coverage, .scanned)
        XCTAssertEqual(withoutIndex.section(.transcript)?.total, 1)
    }

    func testAnOutdatedIndexFileStartsOverAndSaysSo() throws {
        let file = root.appendingPathComponent("v2.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        let v2 = """
            CREATE TABLE doc(id INTEGER PRIMARY KEY, patient TEXT, session TEXT NOT NULL, kind TEXT NOT NULL,
                date REAL NOT NULL, fp TEXT NOT NULL, lines INTEGER NOT NULL, tokens INTEGER NOT NULL, UNIQUE(session, kind, fp));
            PRAGMA user_version = 2;
            """
        XCTAssertEqual(sqlite3_exec(db, v2, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let outdated = SearchIndex(url: file)
        var resets = 0
        outdated.onReset = { resets += 1 }
        outdated.progress.checked(stale: [])
        XCTAssertEqual(outdated.counts().docs, 0)
        XCTAssertEqual(resets, 1, "the owner is told to sweep again")
        XCTAssertFalse(outdated.progress.snapshot().checked, "coverage is unknown until it has")
        let text = "[00:01] A: The garden."
        outdated.replace(
            session: "s", patient: "p", kinds: [.transcript],
            items: [SearchIndex.Item(session: "s", patient: "p", kind: "transcript", date: 0, fingerprint: SearchIndex.fingerprint(of: text), text: text)],
            stamp: "1")
        guard case .found(let documents, _) = outdated.matchLive(clauses: ["\"garden\" *"]) else { return XCTFail("readable") }
        XCTAssertEqual(documents.count, 1)
    }

    // MARK: Cost and limits

    func testAQueryReadsOnlyTheTranscriptsItShows() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        for day in 1...30 {
            let session = try store.createSession(for: patient, on: date(2026, 1, 1).addingTimeInterval(Double(day) * 86_400))
            let extra = day == 17 ? " Kayaking helped." : ""
            try store.saveTranscript("[00:01] You: The garden, day \(day).\(extra)", for: patient, session: session)
        }
        store.syncSearchIndex()
        index.flush()
        var reads = 0
        var reader = store.searchReader
        let read = reader.transcript
        reader.transcript = { patient, session in
            reads += 1
            return read(patient, session)
        }
        func run(_ text: String, _ limits: GlobalSearchLimits = GlobalSearchLimits()) -> GlobalSearchResults {
            reads = 0
            let found = GlobalSearchEngine.search(
                GlobalSearchQuery(text), catalog: store.searchCatalog(), index: index, reader: reader,
                limits: limits, calendar: calendar, shouldContinue: { true })
            return found ?? .empty
        }

        XCTAssertEqual(run("kayaking").section(.transcript)?.total, 1)
        XCTAssertEqual(reads, 1)

        let garden = run("garden")
        XCTAssertEqual(garden.section(.transcript)?.total, 30)
        XCTAssertEqual(garden.section(.transcript)?.hits.count, GlobalSearchLimits.initial)
        XCTAssertEqual(garden.section(.transcript)?.hiddenCount, 25)
        XCTAssertEqual(reads, GlobalSearchLimits.initial)

        var more = GlobalSearchLimits()
        more.showMore(of: .transcript)
        XCTAssertEqual(run("garden", more).section(.transcript)?.hits.count, 30)
        XCTAssertEqual(reads, 30)

        XCTAssertEqual(run("garden").hits.map(\.id), garden.hits.map(\.id), "the same query gives the same order")
    }

    func testASupersededQueryStops() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        try store.saveTranscript("[00:01] You: The garden.", for: patient, session: session)
        store.syncSearchIndex()
        XCTAssertEqual(store.globalSearch(query: "garden", calendar: calendar, shouldContinue: { false }), .empty)
        XCTAssertEqual(store.globalSearch(query: "", calendar: calendar), .empty)
    }
}
