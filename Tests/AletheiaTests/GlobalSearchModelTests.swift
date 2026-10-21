import AppKit
import SwiftUI
import XCTest
@testable import Aletheia

/// The one search field: its rows and keyboard selection, "Show more", where
/// opening a result goes, what VoiceOver hears, ⌘F, and that the old patient
/// filter and search sheet are gone.
final class GlobalSearchModelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlobalSearchModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source(_ path: String) throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    /// A store with an index, `count` sessions of Jane's whose transcripts mention the garden.
    private func makeStore(sessions count: Int) throws -> (Store, SearchIndex, Patient) {
        let index = SearchIndex(url: root.appendingPathComponent("search.sqlite"))
        let store = Store(root: root, searchIndex: index)
        let patient = try store.createPatient(name: "Jane Doe")
        let calendar = Calendar(identifier: .gregorian)
        for day in 1...count {
            let date = calendar.date(from: DateComponents(year: 2026, month: 5, day: day, hour: 12))!
            let session = try store.createSession(for: patient, on: date)
            try store.saveTranscript("[00:01] You: Jane talked about the garden, day \(day).", for: patient, session: session)
        }
        store.syncSearchIndex()
        index.flush()
        return (store, index, patient)
    }

    private func hit(_ id: String, _ kind: SearchKind, session: Bool = true) -> SearchHit {
        let patient = Patient(name: "Jane Doe", slug: "Jane-Doe")
        return SearchHit(
            id: id, kind: kind, patient: patient,
            session: session ? SessionRecord(patientId: patient.id, folderName: "s") : nil, snippet: "")
    }

    // MARK: Rows and selection (pure)

    func testRowsListEachGroupThenItsShowMore() {
        let results = GlobalSearchResults(
            sections: [
                GlobalSearchSection(kind: .patient, hits: [hit("p", .patient, session: false)], total: 1),
                GlobalSearchSection(kind: .transcript, hits: [hit("t1", .transcript), hit("t2", .transcript)], total: 9),
            ],
            coverage: .complete, unsearchedWords: [])
        let rows = GlobalSearchRow.rows(for: results, limits: GlobalSearchLimits())
        XCTAssertEqual(rows.map(\.id), ["p", "t1", "t2", "more-transcript"])
        XCTAssertEqual(rows.last, .more(.transcript, hidden: 7))
        XCTAssertEqual(GlobalSearchRow.moreTitle(hidden: 7), "Show 7 more")
        XCTAssertEqual(GlobalSearchRow.moreTitle(hidden: 395), "Show 25 more of 395")

        var full = GlobalSearchLimits()
        while full.showMore(of: .transcript) {}
        XCTAssertEqual(GlobalSearchRow.rows(for: results, limits: full).map(\.id), ["p", "t1", "t2"], "no Show more past the maximum")
        XCTAssertEqual(
            GlobalSearchRow.cappedNote(for: results.sections[1], limits: full),
            "Showing the first 2 of 9. Add a word to narrow the search.")
        XCTAssertNil(GlobalSearchRow.cappedNote(for: results.sections[1], limits: GlobalSearchLimits()))
    }

    func testArrowsMoveThroughEveryGroupAndStopAtTheEnds() {
        let rows: [GlobalSearchRow] = [.hit(hit("a", .patient, session: false)), .hit(hit("b", .note)), .more(.note, hidden: 3)]
        XCTAssertEqual(GlobalSearchRow.move(from: nil, by: 1, in: rows), "a")
        XCTAssertEqual(GlobalSearchRow.move(from: nil, by: -1, in: rows), "more-note")
        XCTAssertEqual(GlobalSearchRow.move(from: "a", by: 1, in: rows), "b")
        XCTAssertEqual(GlobalSearchRow.move(from: "more-note", by: 1, in: rows), "more-note")
        XCTAssertEqual(GlobalSearchRow.move(from: "b", by: -5, in: rows), "a")
        XCTAssertEqual(GlobalSearchRow.move(from: "gone", by: 1, in: rows), "a")
        XCTAssertNil(GlobalSearchRow.move(from: "a", by: 1, in: []))
    }

    func testEmptyMessagesSayWhy() {
        let common = GlobalSearchResults(sections: [], coverage: .complete, unsearchedWords: ["the"])
        XCTAssertEqual(
            GlobalSearchRow.emptyMessage(query: "the", results: common),
            "\u{201C}the\u{201D} is too common or too short to search notes and transcripts for. Add another word.")
        XCTAssertEqual(GlobalSearchRow.emptyMessage(query: " kayak ", results: .empty), "No results for \u{201C}kayak\u{201D}")
        let indexing = GlobalSearchResults(sections: [], coverage: .indexing(sessions: 3), unsearchedWords: [])
        XCTAssertEqual(GlobalSearchRow.emptyMessage(query: "kayak", results: indexing), "No results yet for \u{201C}kayak\u{201D}")
    }

    func testVoiceOverHearsTheCountAndWhetherItMayBeIncomplete() {
        XCTAssertEqual(GlobalSearchAnnouncement.text(for: .empty), "No results")
        let one = GlobalSearchResults(
            sections: [GlobalSearchSection(kind: .note, hits: [hit("n", .note)], total: 1)], coverage: .complete, unsearchedWords: [])
        XCTAssertEqual(GlobalSearchAnnouncement.text(for: one), "1 result in 1 group")
        let many = GlobalSearchResults(
            sections: [
                GlobalSearchSection(kind: .note, hits: [hit("n", .note)], total: 4),
                GlobalSearchSection(kind: .transcript, hits: [hit("t", .transcript)], total: 8),
            ],
            coverage: .indexing(sessions: 2), unsearchedWords: [])
        XCTAssertEqual(GlobalSearchAnnouncement.text(for: many), "12 results in 2 groups. Indexing 2 sessions; results may be incomplete.")
    }

    // MARK: Opening

    func testOpeningAResultGoesWhereTheMatchIs() {
        let patient = Patient(name: "Jane Doe", slug: "Jane-Doe")
        let session = SessionRecord(patientId: patient.id, folderName: "s")
        func destination(_ kind: SearchKind, format: ProgressNoteFormat? = nil, comment: String? = nil, inSession: Bool = true) -> SearchHitDestination {
            SearchHitDestination(SearchHit(
                id: "x", kind: kind, patient: patient, session: inSession ? session : nil,
                noteFormat: format, commentID: comment, snippet: ""))
        }
        let toPatient = destination(.patient, inSession: false)
        XCTAssertEqual(toPatient.patientID, patient.id)
        XCTAssertNil(toPatient.sessionID)
        XCTAssertNil(toPatient.tab)

        XCTAssertEqual(destination(.transcript).tab, .transcript)
        XCTAssertEqual(destination(.session).tab, .transcript)
        XCTAssertEqual(destination(.session).sessionID, session.id)
        let note = destination(.note, format: .birp)
        XCTAssertEqual(note.tab, .notes)
        XCTAssertEqual(note.noteFormat, .birp)
        XCTAssertFalse(note.showingMyNotes)
        let mine = destination(.sessionNotes)
        XCTAssertEqual(mine.tab, .notes)
        XCTAssertTrue(mine.showingMyNotes)
        let comment = destination(.comment, comment: "c1")
        XCTAssertEqual(comment.tab, .transcript)
        XCTAssertEqual(comment.commentID, "c1")
    }

    // MARK: The model, against a real store

    @MainActor
    func testTypingSearchesAndSelectsTheFirstResult() async throws {
        let (store, _, patient) = try makeStore(sessions: 2)
        let model = GlobalSearchModel(debounceNanoseconds: 0)
        XCTAssertFalse(model.hasQuery)
        model.query = "jane"
        XCTAssertTrue(model.hasQuery)
        await model.run(store: store)
        XCTAssertEqual(model.results.sections.map(\.kind), [.patient, .transcript])
        XCTAssertEqual(model.selectedID, "patient-\(patient.id.uuidString)")

        XCTAssertTrue(model.move(by: 1))
        let first = try XCTUnwrap(model.results.section(.transcript)?.hits.first)
        XCTAssertEqual(model.selectedID, first.id)
        XCTAssertEqual(model.activate(), .open(first))

        model.query = "  "
        await model.run(store: store)
        XCTAssertEqual(model.results, .empty)
        XCTAssertNil(model.selectedID)
        XCTAssertFalse(model.move(by: 1))
        XCTAssertNil(model.activate())
    }

    @MainActor
    func testShowMoreGrowsTheGroupAndSelectsTheFirstNewResult() async throws {
        let (store, _, _) = try makeStore(sessions: 7)
        let model = GlobalSearchModel(debounceNanoseconds: 0)
        model.query = "garden"
        await model.run(store: store)
        let transcripts = try XCTUnwrap(model.results.section(.transcript))
        XCTAssertEqual(transcripts.total, 7)
        XCTAssertEqual(transcripts.hits.count, GlobalSearchLimits.initial)
        XCTAssertEqual(model.rows.last?.id, "more-transcript")

        XCTAssertEqual(model.activate("more-transcript"), .expanded(.transcript))
        XCTAssertEqual(model.limits.limit(for: .transcript), GlobalSearchLimits.initial + GlobalSearchLimits.step)
        await model.run(store: store)
        let grown = try XCTUnwrap(model.results.section(.transcript))
        XCTAssertEqual(grown.hits.count, 7)
        XCTAssertEqual(model.selectedID, grown.hits[GlobalSearchLimits.initial].id, "the first newly shown result")
        XCTAssertFalse(model.rows.contains { $0.id == "more-transcript" })

        model.query = "garden day"
        XCTAssertEqual(model.limits, GlobalSearchLimits(), "a new query starts from the first few again")
        model.clear()
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.results, .empty)
        XCTAssertNil(model.selectedID)
    }

    @MainActor
    func testAReRunKeepsTheSelectedResult() async throws {
        let (store, _, _) = try makeStore(sessions: 3)
        let model = GlobalSearchModel(debounceNanoseconds: 0)
        model.query = "garden"
        await model.run(store: store)
        model.move(by: 2)
        let selected = model.selectedID
        await model.run(store: store)   // the index changed, say
        XCTAssertEqual(model.selectedID, selected)
    }

    @MainActor
    func testASupersededRunChangesNothing() async throws {
        let (store, _, _) = try makeStore(sessions: 2)
        let model = GlobalSearchModel(debounceNanoseconds: 5_000_000_000)
        model.query = "garden"
        let run = Task { await model.run(store: store) }
        run.cancel()
        await run.value
        XCTAssertEqual(model.results, .empty, "a cancelled run (the next keystroke) leaves no results behind")
    }

    // MARK: ⌘F

    func testCommandFIsListedAndBound() throws {
        XCTAssertEqual(ShortcutGlyphs.symbols(for: AppHotkey.search), "⌘F")
        let entries = ShortcutCatalog.sections.flatMap(\.entries)
        XCTAssertEqual(entries.first { $0.title == "Search everything" }.map { ShortcutGlyphs.symbols(for: $0.shortcut) }, "⌘F")
        let field = try source("Sources/App/Views/GlobalSearchField.swift")
        XCTAssertTrue(field.contains(".shortcut(AppHotkey.search, help: \"Search everything\")"))
        XCTAssertTrue(field.contains("ShortcutHint(AppHotkey.search)"))
        XCTAssertTrue(try source("Sources/App/Views/RootView.swift").contains("GlobalSearchHotkey(isFocused: isFocused)"))
    }

    @MainActor
    func testCommandFFindsInATranscriptOrNoteAndFocusesSearchElsewhere() {
        let transcript = NSTextView()
        transcript.usesFindBar = true
        XCTAssertTrue(GlobalSearchShortcut.findableTextView(transcript) === transcript)

        let fieldEditor = NSTextView()
        fieldEditor.usesFindBar = true
        fieldEditor.isFieldEditor = true
        XCTAssertNil(GlobalSearchShortcut.findableTextView(fieldEditor), "the search field's own editor")

        XCTAssertNil(GlobalSearchShortcut.findableTextView(NSTextView()), "a text view without a find bar")
        XCTAssertNil(GlobalSearchShortcut.findableTextView(NSView()))
        XCTAssertNil(GlobalSearchShortcut.findableTextView(nil))
    }

    // MARK: Highlighting

    func testRowsMarkTheWordsTheSearchMatched() {
        let marked = GlobalSearchHighlight.segments(in: "She worried; therapy helped.", query: "worries thera")
        XCTAssertEqual(marked.filter(\.isMatch).map(\.text), ["worried", "therapy"])
        XCTAssertEqual(marked.map(\.text).joined(), "She worried; therapy helped.")
        let name = GlobalSearchHighlight.segments(in: "Joanne Smith", query: "ann")
        XCTAssertEqual(name.filter(\.isMatch).map(\.text), ["ann"], "falls back to where the typed text is")
    }

    // MARK: One field

    func testThereIsOneSearchField() throws {
        let list = try source("Sources/App/Views/PatientsListView.swift")
        XCTAssertFalse(list.contains(".searchable("), "the sidebar has no filter field of its own")
        XCTAssertTrue(list.contains("List(appModel.patients, selection:"), "and is not filtered while searching")
        let rootView = try source("Sources/App/Views/RootView.swift")
        XCTAssertFalse(rootView.contains("GlobalSearchView("), "no separate search sheet")
        XCTAssertTrue(rootView.contains("ToolbarItem(placement: .primaryAction) {\n                        GlobalSearchField("))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/App/Views/GlobalSearchView.swift").path))
    }
}
