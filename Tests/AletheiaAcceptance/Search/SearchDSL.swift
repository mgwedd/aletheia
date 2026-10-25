@testable import Aletheia
import AppKit
import Foundation
import XCTest

// MARK: - Subjects

/// The search field with what it has typed and the results under it.
@MainActor
final class SearchBox {
    fileprivate let model = GlobalSearchModel(debounceNanoseconds: 0)
    fileprivate let store: Store
    fileprivate init(store: Store) { self.store = store }

    var query: String { model.query }
    var results: GlobalSearchResults { model.results }
    var hits: [SearchHit] { model.results.hits }
    var groupNames: [String] { model.results.sections.map(\.kind.filterLabel) }
    func hits(in group: String) -> [SearchHit] { model.results.sections.first { $0.kind.filterLabel == group }?.hits ?? [] }
    func total(in group: String) -> Int { model.results.sections.first { $0.kind.filterLabel == group }?.total ?? 0 }
}

/// A result the therapist opened, and where it took them.
struct OpenedResult {
    let hit: SearchHit
    let destination: SearchHitDestination
    let transcript: String?
    let query: String
}

/// What a key press did while the cursor was in a transcript.
@MainActor
struct KeyPress {
    let route: GlobalSearchShortcut.Route
}

/// A hold on the search index's background work, as when a transcript was only just saved.
@MainActor
final class IndexHold {
    private let gate = DispatchSemaphore(value: 0)
    fileprivate init() {
        let gate = gate
        SessionSearch.index.async { _ = gate.wait(timeout: .now() + 30) }
    }
    func release() {
        gate.signal()
        SessionSearch.index.flush()
    }
}

/// A Mac locked by Aletheia's app lock.
@MainActor
final class LockedApp {
    fileprivate let lock: AppLock
    fileprivate init(lock: AppLock) { self.lock = lock }
}

/// Whether a search made while locked had anything to answer from.
struct LockedSearch { let hadAnythingToSearch: Bool }

/// What Aletheia put in Spotlight.
final class RecordingSpotlight: SpotlightIndexing {
    private(set) var entries: [SpotlightEntry] = []
    func replaceIndex(with entries: [SpotlightEntry]) { self.entries = entries }
    func clear() { entries = [] }
}

struct SpotlightListing {
    let entries: [SpotlightEntry]
}

/// The calendar day the fixtures use.
func searchDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

// MARK: - Given

extension Given {
    /// A session on `date` whose transcript reads `text`.
    @discardableResult
    func session(for patient: Patient, on date: Date, transcript text: String) throws -> SessionRecord {
        let store = try XCTUnwrap(app.appModel.store)
        let session = try store.createSession(for: patient, on: date)
        try store.saveTranscript(text, for: patient, session: session)
        app.appModel.refreshPatients()
        return session
    }

    func myNotes(_ text: String, on session: SessionRecord) {
        app.appModel.saveNote(sessionID: session.id, text: text)
    }

    func progressNote(_ text: String, for patient: Patient, on session: SessionRecord) throws {
        try XCTUnwrap(app.appModel.store).saveNote(text, for: patient, session: session, format: .soap)
    }

    func comment(_ body: String, on passage: String, at seconds: Double, in session: SessionRecord) {
        _ = app.appModel.addComment(
            sessionID: session.id, quotedText: passage, body: body, anchorSeconds: seconds, quoteStart: nil)
    }

    /// The saved transcript is still waiting to be indexed.
    func searchIndexIsBusy() async -> IndexHold {
        await When(app: app).waitForSearchToCatchUp()
        return IndexHold()
    }
}

// MARK: - When

extension When {
    /// Waits until the search covers everything saved so far.
    func waitForSearchToCatchUp() async {
        let index = SessionSearch.index
        index.flush()
        for _ in 0..<80 {
            let snapshot = index.progress.snapshot()
            if snapshot.checked && snapshot.pendingSessions == 0 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        app.appModel.store?.syncSearchIndex()
        index.flush()
    }

    /// Types into the search field and lets the results come in.
    func typeInSearch(_ text: String) async throws -> SearchBox {
        await waitForSearchToCatchUp()
        return try await typeInSearchRightAway(text)
    }

    /// Types into the search field without waiting for anything saved to be indexed.
    func typeInSearchRightAway(_ text: String) async throws -> SearchBox {
        let box = SearchBox(store: try XCTUnwrap(app.appModel.store))
        box.model.query = text
        await box.model.run(store: box.store)
        return box
    }

    /// The results refresh when the index changes underneath them.
    func resultsRefresh(_ box: SearchBox) async { await box.model.run(store: box.store) }

    func pressDown(in box: SearchBox) { box.model.move(by: 1) }

    /// Presses Return on the selected row; nil when it is a "Show more" row or nothing is selected.
    func pressReturn(in box: SearchBox) throws -> OpenedResult? {
        guard case .open(let hit)? = box.model.activate() else { return nil }
        let store = try XCTUnwrap(app.appModel.store)
        return OpenedResult(
            hit: hit, destination: SearchHitDestination(hit),
            transcript: hit.session.flatMap { store.transcript(for: hit.patient, session: $0) },
            query: box.query)
    }

    /// Selects a group's "Show more" row and presses Return.
    func pressReturnOnShowMore(of group: String, in box: SearchBox) async {
        guard let row = box.model.rows.first(where: {
            if case .more(let kind, _) = $0 { return kind.filterLabel == group }
            return false
        }) else { return }
        box.model.select(row.id)
        _ = box.model.activate()
        await box.model.run(store: box.store)
    }

    /// Presses command-F with the cursor in the session's transcript.
    func pressCommandF(withCursorInTranscriptOf session: SessionRecord) -> KeyPress {
        let transcript = NSTextView()
        transcript.usesFindBar = true
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
            context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
        return KeyPress(route: GlobalSearchShortcut.route(event, firstResponder: transcript))
    }

    func pressEscape(in box: SearchBox) { box.model.clear() }

    func quitDeleteTheSearchFileAndReopen() async {
        await app.appModel.stopSearchSync()
        for name in ["search.sqlite", "search.sqlite-wal", "search.sqlite-shm"] {
            try? FileManager.default.removeItem(at: app.root.appendingPathComponent(name))
        }
        app.relaunch(tier: app.tier)
    }

    func lockTheApp() -> LockedApp {
        app.settings.appLockEnabled = true
        let lock = AppLock(
            settings: app.settings, canAuthenticate: { true }, authenticator: AlwaysUnlocks(),
            isAppActive: { true }, spotlight: SilentSpotlight())
        lock.lockIfEnabled()
        return LockedApp(lock: lock)
    }

    func unlock(_ locked: LockedApp) async { await locked.lock.unlock() }

    /// Searches while the app is locked, as far as the search itself can tell.
    func searchWhileLocked(for text: String) throws -> LockedSearch {
        let store = try XCTUnwrap(app.appModel.store)
        let answer = GlobalSearchEngine.search(
            GlobalSearchQuery(text), catalog: store.searchCatalog(), index: SessionSearch.index,
            reader: store.searchReader, limits: GlobalSearchLimits(), calendar: .current, shouldContinue: { true })
        return LockedSearch(hadAnythingToSearch: answer != nil)
    }

    /// Turns on "Find patients in Spotlight" and lets Aletheia fill Spotlight.
    func turnOnFindPatientsInSpotlight() -> SpotlightListing {
        let recorder = RecordingSpotlight()
        app.settings.spotlightIndexingEnabled = true
        let model = AppModel(
            settings: app.settings, encryption: app.encryption, spotlightIndexer: recorder,
            featureRegistry: .compose(tier: app.tier, from: FeatureRegistry.allModules))
        model.reindexSpotlight()
        return SpotlightListing(entries: recorder.entries)
    }

    func deleteWithAllRecords(_ patient: Patient) throws { try app.appModel.deletePatient(patient) }
}

private struct AlwaysUnlocks: UnlockAuthenticator {
    func authenticate(reason: String) async throws -> Bool { true }
}

// MARK: - Then

@MainActor extension Then where Subject == SearchBox {
    func showsResultsOverThePage(including kind: String) {
        expect(subject.model.hasQuery, "typing \u{201C}\(subject.query)\u{201D} did not start a search")
        expect(!subject.hits(in: kind).isEmpty, "no \(kind) result for \u{201C}\(subject.query)\u{201D}")
    }

    func groupsAre(_ names: [String]) {
        expectEqual(subject.groupNames, names, "the groups of results")
    }

    func highlightsTheMatch(of word: String, in groups: [String]) {
        for group in groups {
            let hits = subject.hits(in: group)
            expect(!hits.isEmpty, "no \(group) result")
            for hit in hits {
                let marked = GlobalSearchHighlight.segments(in: hit.snippet, query: subject.query)
                    .filter(\.isMatch).map(\.text)
                expect(
                    marked.contains { $0.localizedCaseInsensitiveContains(word) },
                    "the \(group) snippet \u{201C}\(hit.snippet)\u{201D} does not highlight \u{201C}\(word)\u{201D}")
            }
        }
    }

    func showsOnly(_ shown: Int, of total: Int, in group: String) {
        expectEqual(subject.hits(in: group).count, shown, "results shown in \(group)")
        expectEqual(subject.total(in: group), total, "matches in \(group)")
    }

    func offersShowMore(_ hidden: Int, in group: String) {
        let titles = subject.model.rows.compactMap { row -> String? in
            if case .more(let kind, let count) = row, kind.filterLabel == group { return GlobalSearchRow.moreTitle(hidden: count) }
            return nil
        }
        expectEqual(titles, [Copy.showMore(hidden)], "the \u{201C}Show more\u{201D} rows under \(group)")
    }

    func offersNoMoreIn(_ group: String) {
        let more = subject.model.rows.contains { if case .more(let kind, _) = $0 { return kind.filterLabel == group }; return false }
        expect(!more, "\(group) still offers \u{201C}Show more\u{201D}")
    }

    func hasSelectedTheSecondResult() {
        let rows = subject.model.rows
        expect(rows.count >= 2, "need two results to move between, found \(rows.count)")
        expectEqual(subject.model.selectedID, rows.count >= 2 ? rows[1].id : nil, "the selected row")
    }

    func isCleared() {
        expectEqual(subject.query, "", "the search field")
        expect(subject.hits.isEmpty, "results are still showing")
        expect(!subject.model.hasQuery, "the results still cover the page")
    }

    func listsSessions(onDays days: [Date], in group: String = "Transcripts") {
        let found = subject.hits(in: group).compactMap { $0.session?.date }
        expectEqual(found, days, "dates of the \(group) results")
    }

    func saysNoResults() {
        expectEqual(subject.hits.count, 0, "number of results")
        expectEqual(
            GlobalSearchRow.emptyMessage(query: subject.query, results: subject.results),
            Copy.noResults(for: subject.query), "what the results say")
    }

    func warnsResultsMayBeIncomplete() {
        expectEqual(subject.results.coverage.statusText, Copy.indexingOneSession, "the line above the results")
    }

    func hasNoWarning() {
        expectEqual(subject.results.coverage.statusText, nil, "the line above the results")
    }

    func includesTranscriptOf(_ session: SessionRecord) {
        expect(
            subject.hits(in: "Transcripts").contains { $0.session?.id == session.id },
            "no transcript result for that session")
    }

    func givesTheSameResultsAs(_ other: SearchBox) {
        expect(!other.hits.isEmpty, "the comparison search found nothing, so it proves nothing")
        expectEqual(subject.hits.map(\.id), other.hits.map(\.id), "results for \u{201C}\(subject.query)\u{201D} against \u{201C}\(other.query)\u{201D}")
    }

    func onlyShowSessions(of patient: Patient) {
        expect(!subject.hits.isEmpty, "nothing found")
        expect(subject.hits.allSatisfy { $0.patient.id == patient.id }, "results from someone other than \(patient.name)")
    }

    func mentionNobodyNamed(_ name: String) {
        expect(
            !subject.hits.contains { $0.patient.name == name || $0.title.contains(name) || $0.snippet.contains(name) },
            "a result still mentions \(name)")
        expectEqual(subject.hits.count, 0, "number of results")
    }
}

@MainActor extension Then where Subject == KeyPress {
    func movesTheCursorToTheSearchField() {
        if case .focusSearch = subject.route { return }
        fail("command-F with the cursor in a transcript did not focus the search field; it was \(subject.route)")
    }
}

extension Then where Subject == OpenedResult {
    func opensTheTranscriptOf(_ session: SessionRecord) {
        expectEqual(subject.destination.sessionID, session.id, "the session opened")
        expectEqual(subject.destination.tab, .transcript, "the tab opened")
    }

    func scrollsToAndMarks(_ word: String, onLineContaining line: String) {
        guard let transcript = subject.transcript,
              let range = subject.destination.searchFocus(query: subject.query)?.transcriptRange(in: transcript),
              let swiftRange = Range(range, in: transcript) else {
            return fail("the opened session has no match to scroll to")
        }
        expectEqual(String(transcript[swiftRange]).lowercased(), word.lowercased(), "the marked word")
        let lineRange = transcript.lineRange(for: swiftRange)
        expect(
            transcript[lineRange].contains(line),
            "the marked word is on \u{201C}\(transcript[lineRange])\u{201D}, not the line with \u{201C}\(line)\u{201D}")
    }
}

extension Then where Subject == LockedSearch {
    func findsNothing() { expect(!subject.hadAnythingToSearch, "the search still had an index to answer from while locked") }
}

extension Then where Subject == SpotlightListing {
    func listsPatientsByInitialsOnly(hiding names: [String]) {
        expect(!subject.entries.isEmpty, "nothing was listed in Spotlight")
        let titles = subject.entries.map(\.title)
        expect(titles.first { $0.hasPrefix("J.D.") } != nil, "no entry is titled with the initials, found \(titles)")
        for entry in subject.entries {
            let everything = ([entry.title, entry.contentDescription] + entry.keywords).joined(separator: " ")
            for name in names {
                expect(!everything.localizedCaseInsensitiveContains(name), "Spotlight shows \u{201C}\(name)\u{201D} in \u{201C}\(entry.title)\u{201D}")
            }
        }
    }
}
