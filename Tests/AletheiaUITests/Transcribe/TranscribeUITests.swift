import XCTest

/// Transcription and the transcript in the real app.
final class TranscribeUITests: AcceptanceCase {
    func test_TRANSCRIBE_19_progressBandTitleReadsJustTranscribing() {
        given.aSessionBeingTranscribed()
        when.importARecording()

        let title = app.text(containing: Copy.transcribingTitle)
        XCTAssertTrue(app.exists(title), "no progress band")

        then(title).bandReadsJustTranscribing()
        then(title.label.isEmpty ? (title.value as? String ?? "") : title.label)
            .isExactly(Copy.transcribingTitle)
    }

    func test_TRANSCRIBE_20_clientTurnsStartWithFirstNameAndWrapLikeTheTherapists() {
        given.aTranscriptWithALongTurn(by: "You", run: "therapist-\(UUID().uuidString.lowercased())")
        let therapist = when.readTranscript()

        given.aTranscriptWithALongTurn(by: "Call audio", run: "client-\(UUID().uuidString.lowercased())")
        let client = when.readTranscript()

        then(client.transcript).clientTurnStartsWithFirstName("Jane")
        then(client.lines).wrapsAcrossThePaneLike(therapist.lines)
    }
}

extension Then where Subject == String {
    func isExactly(_ expected: String) {
        expect(subject == expected, "the band reads \"\(subject)\", not \"\(expected)\"")
    }
}

extension Then where Subject == Int {
    /// More than a couple of lines, and within a line of the therapist's.
    func wrapsAcrossThePaneLike(_ therapistLines: Int) {
        expect(subject > 3, "the client's turn took \(subject) lines; it should wrap across the pane")
        expect(abs(subject - therapistLines) <= 1, "the client's turn took \(subject) lines, the therapist's \(therapistLines)")
    }
}
