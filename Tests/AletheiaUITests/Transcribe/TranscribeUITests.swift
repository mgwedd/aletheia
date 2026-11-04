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

    func test_TRANSCRIBE_21_aCallOnSpeakersShowsTheClientsWordsOnce() {
        let waking = "I keep waking up at three and I can't get back to sleep."
        let work = "work has been really stressful lately."
        given.aCallOnSpeakers([
            .init(speaker: "Call audio", from: 10, to: 15, text: waking),
            .init(speaker: "You", from: 10, to: 15, text: waking),
            .init(speaker: "Call audio", from: 18, to: 21, text: "And \(work)"),
            .init(speaker: "You", from: 18, to: 23, text: "Take your time, there's no rush, and \(work)"),
            .init(speaker: "You", from: 40, to: 44, text: "So you keep waking up at three and can't get back to sleep."),
        ])
        when.importARecording()
        let transcript = when.readTranscript().transcript

        then(transcript).says(waking, once: "Jane")
        then(transcript).says(work, once: "Jane")
        then(transcript).says("Take your time, there's no rush", once: "You")
        then(transcript).says("So you keep waking up at three", once: "You")
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
