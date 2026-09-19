import XCTest
@testable import Aletheia

/// Behaviour the generic persistence core must have, exercised against the
/// in-memory implementation (the SQLite-backed core will run the same shape in
/// a later slice). These pin the contract the domain repositories rely on:
/// identity by `(kind, id)`, owner/item scoping, stable ordering, upsert.
final class PersistenceCoreTests: XCTestCase {
    private var core: InMemoryPersistenceCore!

    override func setUp() {
        super.setUp()
        core = InMemoryPersistenceCore()
    }

    private func record(
        _ id: String,
        kind: String,
        owner: UUID? = nil,
        item: UUID? = nil,
        body: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
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
        XCTAssertEqual(core.records(kind: "note", itemID: UUID()).count, 0)
        XCTAssertEqual(core.record(kind: "note", id: "x").map { String(decoding: $0.payload, as: UTF8.self) }, "second")
    }

    func testRemove() {
        core.put(record("gone", kind: "comment", body: "b"))
        XCTAssertTrue(core.remove(kind: "comment", id: "gone"))
        XCTAssertNil(core.record(kind: "comment", id: "gone"))
        XCTAssertTrue(core.remove(kind: "comment", id: "gone"), "removing an absent record is not an error")
    }

    /// The singleton pattern the adapter uses for one-per-item records (a
    /// session's note or chat): key the record by the item's own id.
    func testSingletonKeyedByItemID() {
        let session = UUID()
        core.put(record(session.uuidString, kind: "note", item: session, body: "the note"))
        XCTAssertEqual(core.record(kind: "note", id: session.uuidString).map { String(decoding: $0.payload, as: UTF8.self) },
                       "the note")
        XCTAssertEqual(core.records(kind: "note", itemID: session).count, 1)
    }
}
