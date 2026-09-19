import XCTest
@testable import SessionNotes

/// The SQLite-backed core must satisfy the same `PersistenceCore` contract the
/// in-memory fake pins (identity by `(kind, id)`, owner/item scoping, oldest-first
/// ordering, upsert, forgiving remove), plus the things only a real file store
/// can get wrong: durability across a reopen, binary and empty payloads, and a
/// consistent snapshot.
final class SQLitePersistenceCoreTests: XCTestCase {
    private var root: URL!
    private var dbURL: URL!
    private var core: SQLitePersistenceCore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLitePersistenceCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        dbURL = root.appendingPathComponent("core.sqlite")
        core = try XCTUnwrap(SQLitePersistenceCore(url: dbURL))
    }

    override func tearDownWithError() throws {
        core = nil
        try? FileManager.default.removeItem(at: root)
    }

    // A fixed, integer-second default so equality assertions are exact: the core
    // round-trips dates through `timeIntervalSince1970`, and a live `Date()` can
    // drift by a sub-microsecond ULP across the reference-date offset, which would
    // make full-record `==` checks flaky. Whole seconds survive the round trip.
    private static let fixedDate = Date(timeIntervalSince1970: 1_600_000_000)

    private func record(
        _ id: String,
        kind: String,
        owner: UUID? = nil,
        item: UUID? = nil,
        body: String = "",
        createdAt: Date = SQLitePersistenceCoreTests.fixedDate,
        updatedAt: Date = SQLitePersistenceCoreTests.fixedDate
    ) -> PersistedRecord {
        PersistedRecord(id: id, kind: kind, ownerID: owner, itemID: item,
                        payload: Data(body.utf8), createdAt: createdAt, updatedAt: updatedAt)
    }

    func testPutThenGetByIdentity() {
        let r = record("a", kind: "comment", body: "hi")
        XCTAssertTrue(core.put(r))
        XCTAssertEqual(core.record(kind: "comment", id: "a"), r)
        XCTAssertNil(core.record(kind: "comment", id: "missing"))
        XCTAssertNil(core.record(kind: "note", id: "a"), "identity is scoped by kind")
    }

    func testItemScopedQueryIsOldestFirst() {
        let session = UUID()
        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 2000)
        core.put(record("late", kind: "comment", item: session, body: "B", createdAt: t1))
        core.put(record("early", kind: "comment", item: session, body: "A", createdAt: t0))

        let bodies = core.records(kind: "comment", itemID: session).map { String(decoding: $0.payload, as: UTF8.self) }
        XCTAssertEqual(bodies, ["A", "B"], "records come back createdAt-ascending")
    }

    func testOwnerAndItemScopesDoNotBleed() {
        let patientA = UUID(), patientB = UUID()
        let sessionA = UUID(), sessionB = UUID()
        core.put(record("1", kind: "chatThread", owner: patientA, body: "A-thread"))
        core.put(record("2", kind: "chatThread", owner: patientB, body: "B-thread"))
        core.put(record("3", kind: "comment", item: sessionA, body: "A-comment"))
        core.put(record("4", kind: "comment", item: sessionB, body: "B-comment"))

        XCTAssertEqual(core.records(kind: "chatThread", ownerID: patientA).map(\.id), ["1"])
        XCTAssertEqual(core.records(kind: "comment", itemID: sessionB).map(\.id), ["4"])
        XCTAssertTrue(core.records(kind: "comment", ownerID: patientA).isEmpty,
                      "a comment stored only against an item isn't found by owner")
    }

    func testPutReplacesByIdentity() {
        core.put(record("x", kind: "note", body: "first"))
        core.put(record("x", kind: "note", body: "second")) // upsert, not a duplicate
        XCTAssertEqual(core.record(kind: "note", id: "x").map { String(decoding: $0.payload, as: UTF8.self) }, "second")
    }

    func testRemove() {
        core.put(record("gone", kind: "comment", body: "b"))
        XCTAssertTrue(core.remove(kind: "comment", id: "gone"))
        XCTAssertNil(core.record(kind: "comment", id: "gone"))
        XCTAssertTrue(core.remove(kind: "comment", id: "gone"), "removing an absent record is not an error")
    }

    func testSingletonKeyedByItemID() {
        let session = UUID()
        core.put(record(session.uuidString, kind: "note", item: session, body: "the note"))
        XCTAssertEqual(core.record(kind: "note", id: session.uuidString).map { String(decoding: $0.payload, as: UTF8.self) },
                       "the note")
        XCTAssertEqual(core.records(kind: "note", itemID: session).count, 1)
    }

    // MARK: - SQLite-specific behaviour

    /// The whole point of the SQLite core over the in-memory one: records survive
    /// closing and reopening the file.
    func testRecordsSurviveReopen() throws {
        let owner = UUID()
        let t0 = Date(timeIntervalSince1970: 10)
        core.put(record("keep", kind: "chatThread", owner: owner, body: "durable",
                        createdAt: t0, updatedAt: t0))
        core = nil // close the handle

        let reopened = try XCTUnwrap(SQLitePersistenceCore(url: dbURL))
        let got = try XCTUnwrap(reopened.record(kind: "chatThread", id: "keep"))
        XCTAssertEqual(String(decoding: got.payload, as: UTF8.self), "durable")
        XCTAssertEqual(got.ownerID, owner)
        XCTAssertEqual(got.createdAt, t0)
        XCTAssertEqual(reopened.records(kind: "chatThread", ownerID: owner).map(\.id), ["keep"])
    }

    /// Payloads are opaque bytes — arbitrary binary, not just UTF-8 text — and
    /// must round-trip exactly.
    func testBinaryPayloadRoundTrips() throws {
        let blob = Data((0..<512).map { _ in UInt8.random(in: 0...255) })
        core.put(PersistedRecord(id: "bin", kind: "audio", payload: blob))
        XCTAssertEqual(core.record(kind: "audio", id: "bin")?.payload, blob)
    }

    /// An empty payload is a real value, distinct from "no record", and must come
    /// back as empty rather than turning into NULL or a missing row.
    func testEmptyPayloadRoundTrips() throws {
        core.put(PersistedRecord(id: "empty", kind: "note", payload: Data()))
        let got = try XCTUnwrap(core.record(kind: "note", id: "empty"))
        XCTAssertEqual(got.payload, Data())
    }

    /// A record stored with no owner/item scope reads back with nil scopes, not
    /// zero-UUIDs or empty strings.
    func testNilScopesRoundTripAsNil() throws {
        core.put(record("unscoped", kind: "misc", body: "x"))
        let got = try XCTUnwrap(core.record(kind: "misc", id: "unscoped"))
        XCTAssertNil(got.ownerID)
        XCTAssertNil(got.itemID)
    }

    /// `snapshot(to:)` writes a consistent, readable copy while the store is open.
    func testSnapshotProducesReadableCopy() throws {
        let session = UUID()
        core.put(record("c1", kind: "comment", item: session, body: "snapshot me"))

        let dest = root.appendingPathComponent("snapshot.sqlite")
        XCTAssertTrue(core.snapshot(to: dest))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))

        let copy = try XCTUnwrap(SQLitePersistenceCore(url: dest))
        XCTAssertEqual(copy.record(kind: "comment", id: "c1").map { String(decoding: $0.payload, as: UTF8.self) },
                       "snapshot me")
    }
}
