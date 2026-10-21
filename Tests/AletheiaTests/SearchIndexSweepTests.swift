import XCTest
@testable import Aletheia

/// The background sweep that keeps the search index in line with the data
/// folder: it pauses while the Mac is busy, stops when told to, and reports
/// what is still missing.
final class SearchIndexSweepTests: XCTestCase {
    private var root: URL!
    private var index: SearchIndex!
    private var store: Store!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchIndexSweepTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        index = SearchIndex(url: root.appendingPathComponent("search.sqlite"))
        store = Store(root: root, searchIndex: index)
    }

    override func tearDownWithError() throws {
        index.flush()
        try? FileManager.default.removeItem(at: root)
    }

    /// Sessions with a transcript the index hasn't seen (written without the save hook).
    private func makeSessions(_ count: Int) throws -> Patient {
        let patient = try store.createPatient(name: "Jane Doe")
        let plain = Store(root: root)
        for day in 1...count {
            let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 4, day: day, hour: 12))!
            let session = try store.createSession(for: patient, on: date)
            try plain.saveTranscript("[00:01] You: The garden, day \(day).", for: patient, session: session)
        }
        return patient
    }

    func testSweepWaitsWhileBusyThenIndexesEverything() async throws {
        _ = try makeSessions(2)
        var polls = 0
        var indexedWhileBusy = 0
        await SearchIndexSweep.run(
            store: store, index: index,
            isBusy: {
                polls += 1
                guard polls <= 3 else { return false }
                indexedWhileBusy += self.index.counts().docs
                return true
            },
            pollNanoseconds: 1_000_000,
            shouldContinue: { true })
        XCTAssertGreaterThan(polls, 3)
        XCTAssertEqual(indexedWhileBusy, 0, "nothing was indexed while a recording or the model was running")
        XCTAssertEqual(index.counts().docs, 2)
        XCTAssertEqual(index.progress.snapshot(), .init(checked: true, pendingSessions: 0))
        XCTAssertEqual(store.globalSearch(query: "garden").section(.transcript)?.total, 2)
    }

    func testSweepStopsWhenToldAndLeavesTheRestPending() async throws {
        _ = try makeSessions(3)
        var checks = 0
        await SearchIndexSweep.run(
            store: store, index: index, isBusy: { false }, pollNanoseconds: 1_000_000,
            shouldContinue: {
                checks += 1
                return checks <= 2   // one session, then stop
            })
        XCTAssertEqual(index.counts().docs, 1)
        XCTAssertEqual(index.progress.snapshot(), .init(checked: true, pendingSessions: 2))
        XCTAssertEqual(store.globalSearch(query: "garden").coverage, .indexing(sessions: 2))
    }

    func testSweepDropsSessionsThatAreGone() async throws {
        let patient = try makeSessions(2)
        await SearchIndexSweep.run(store: store, index: index, isBusy: { false }, shouldContinue: { true })
        XCTAssertEqual(index.counts().docs, 2)
        let session = try XCTUnwrap(try store.listSessions(for: patient).first)
        try FileManager.default.removeItem(at: store.sessionDir(for: patient, session: session))
        await SearchIndexSweep.run(store: store, index: index, isBusy: { false }, shouldContinue: { true })
        XCTAssertEqual(index.counts().docs, 1)
        XCTAssertNil(index.stamp(session: session.id.uuidString))
    }

    func testANotesOnlySessionIsIndexedOnce() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        store.syncSearchIndex()
        XCTAssertEqual(index.stamp(session: session.id.uuidString), SearchIndexStaleness.noTranscript)
        let plan = try XCTUnwrap(store.searchIndexPlan())
        XCTAssertTrue(plan.staleSessions.isEmpty, "not reported as missing on every launch")
        XCTAssertEqual(plan.live, [session.id.uuidString])
        XCTAssertTrue(plan.complete)
    }

    /// The app wires the sweep to what keeps the Mac busy, and runs it through `SearchIndexSweep`.
    func testTheAppPausesTheSweepForRecordingTranscriptionAndTheModel() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App")
        let root = try String(contentsOf: sources.appendingPathComponent("Views/RootView.swift"), encoding: .utf8)
        for reason in [".recording", ".transcription", ".model"] {
            XCTAssertTrue(root.contains("appModel.searchActivity.set(\(reason), active:"), reason)
        }
        let model = try String(contentsOf: sources.appendingPathComponent("Services/AppModel.swift"), encoding: .utf8)
        XCTAssertTrue(model.contains("await SearchIndexSweep.run("))
        XCTAssertTrue(model.contains("isBusy: { activity.isBusy }"))
        XCTAssertTrue(model.contains("index.onReset = "))
    }
}
