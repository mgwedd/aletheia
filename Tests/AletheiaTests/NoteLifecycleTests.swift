import XCTest
@testable import Aletheia

/// The pure rules for draft and signed progress notes and for the raw
/// transcript file names.
final class NoteLifecycleTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testSha256MatchesAKnownVector() {
        XCTAssertEqual(
            NoteLifecycle.sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testNoRecordReadsAsDraft() {
        XCTAssertEqual(NoteLifecycle.status(record: nil, currentText: "S: calm"), .draft)
        XCTAssertEqual(NoteLifecycle.status(record: nil, currentText: nil), .draft)
    }

    func testMatchingTextReadsAsSigned() {
        let record = NoteLifecycle.sign(text: "S: calm", signer: "mw:501", at: date, aiGenerated: true)
        XCTAssertEqual(NoteLifecycle.status(record: record, currentText: "S: calm"), .signed(record))
        XCTAssertEqual(record.signer, "mw:501")
        XCTAssertEqual(record.signedAt, date)
        XCTAssertTrue(record.aiGenerated)
    }

    func testAnyChangeToSignedTextReadsAsAltered() {
        let record = NoteLifecycle.sign(text: "S: calm", signer: "mw:501", at: date, aiGenerated: false)
        XCTAssertEqual(NoteLifecycle.status(record: record, currentText: "S: calm."), .altered(record))
        XCTAssertEqual(NoteLifecycle.status(record: record, currentText: "S: calm\n"), .altered(record), "exact text, not normalized")
        XCTAssertEqual(NoteLifecycle.status(record: record, currentText: nil), .altered(record))
    }

    func testOnlyADraftAllowsChanges() {
        let record = NoteLifecycle.sign(text: "x", signer: "a", at: date, aiGenerated: false)
        XCTAssertTrue(NoteLifecycle.allowsChanges(.draft))
        XCTAssertFalse(NoteLifecycle.allowsChanges(.signed(record)))
        XCTAssertFalse(NoteLifecycle.allowsChanges(.altered(record)))
    }

    func testRecordRoundTripsThroughJSON() throws {
        let record = NoteLifecycle.sign(text: "x", signer: "a:1", at: date, aiGenerated: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(SignedNote.self, from: try encoder.encode(record)), record)
    }

    // MARK: Raw transcript names

    func testRawTranscriptNamesCountUpAndKeepTheOriginal() {
        XCTAssertEqual(NoteLifecycle.nextRawTranscriptName(existing: ["transcript.txt"]), "transcript.raw.txt")
        XCTAssertEqual(NoteLifecycle.nextRawTranscriptName(existing: ["transcript.raw.txt"]), "transcript.raw.2.txt")
        XCTAssertEqual(
            NoteLifecycle.nextRawTranscriptName(existing: ["transcript.raw.txt", "transcript.raw.2.txt"]),
            "transcript.raw.3.txt")
        XCTAssertEqual(
            NoteLifecycle.nextRawTranscriptName(existing: ["transcript.raw.txt", "transcript.raw.3.txt"]),
            "transcript.raw.2.txt", "fills the lowest free number, never reuses a name")
    }

    func testRawTranscriptNamesAreMatchedByShape() {
        for name in ["transcript.raw.txt", "transcript.raw.2.txt", "transcript.raw.12.txt"] {
            XCTAssertTrue(NoteLifecycle.isRawTranscriptName(name), name)
        }
        for name in ["transcript.txt", "transcript.raw..txt", "transcript.raw.x.txt", "transcript.raw.2.json", "note.soap.txt"] {
            XCTAssertFalse(NoteLifecycle.isRawTranscriptName(name), name)
        }
    }

    func testSignatureFileNameShape() {
        XCTAssertEqual(Store.noteSignatureFileName(for: .soap), "note.soap.signed.json")
        XCTAssertTrue(Store.isNoteSignatureFileName("note.soap.signed.json"))
        XCTAssertTrue(Store.isNoteSignatureFileName("note.retired.signed.json"))
        XCTAssertFalse(Store.isNoteSignatureFileName("note..signed.json"))
        XCTAssertFalse(Store.isNoteSignatureFileName("note.soap.meta.json"))
        XCTAssertFalse(Store.isNoteFileName("note.soap.signed.json"))
        XCTAssertFalse(Store.isNoteMetaFileName("note.soap.signed.json"))
    }
}
