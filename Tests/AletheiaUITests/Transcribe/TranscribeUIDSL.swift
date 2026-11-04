import XCTest

extension Copy {
    static let transcribingTitle = "Transcribing…"
    static let transcriptTab = "Transcript"
    static let importAudio = "Import Audio…"
    static let callAudio = "Call audio"
}

/// The transcript tab on screen.
struct TranscriptOnScreen {
    let driver: AppDriver

    var textView: XCUIElement { driver.app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "[00:")).firstMatch }
    var text: String { (textView.value as? String) ?? "" }
}

extension Given {
    /// Jane Doe with one session whose transcript is a single long turn by `speaker`.
    func aTranscriptWithALongTurn(by speaker: String, run: String? = nil) {
        app.seed {
            if let run { $0.run = run }
            $0.license = "test"
            $0.fileVault = "on"
            $0.patients = [.init(name: "Jane Doe", sessions: 1, transcript: SessionContent.longTurn(by: speaker))]
            $0.open = "Jane Doe"
        }
    }

    /// A call on speakers: Jane's words reach the microphone too, while the
    /// therapist also speaks, and the recording is imported and transcribed.
    func aCallOnSpeakers(_ heard: [FixtureScenario.HeardSegment]) {
        app.seed {
            $0.license = "test"
            $0.fileVault = "on"
            $0.importFile = "clip"
            $0.heardTracks = heard
            $0.patients = [.init(name: "Jane Doe", sessions: 1, recordingConsent: true)]
            $0.open = "Jane Doe"
        }
    }

    /// A session with a recording being transcribed, never finishing.
    func aSessionBeingTranscribed() {
        app.seed {
            $0.license = "test"
            $0.fileVault = "on"
            $0.slowTranscription = true
            $0.importFile = "clip"
            $0.patients = [.init(name: "Jane Doe", sessions: 1, recordingConsent: true)]
            $0.open = "Jane Doe"
        }
    }
}

extension When {
    func importARecording() {
        app.ensureLaunched()
        app.tap(Copy.importAudio)
    }

    /// The transcript once it has laid out, and how many lines it took.
    func readTranscript() -> (transcript: TranscriptOnScreen, lines: Int) {
        app.ensureLaunched()
        let transcript = TranscriptOnScreen(driver: app)
        XCTAssertTrue(app.exists(transcript.textView), "no transcript on screen")
        let probe = app.waitForProbe { $0.transcriptLines > 0 }
        return (transcript, probe.transcriptLines)
    }
}

extension Then where Subject == XCUIElement {
    func bandReadsJustTranscribing() {
        expect(subject.exists, "no progress band titled \"\(Copy.transcribingTitle)\"")
    }
}

extension Then where Subject == TranscriptOnScreen {
    /// `words` appear on one line only, and it is `speaker`'s.
    func says(_ words: String, once speaker: String) {
        let lines = subject.text.components(separatedBy: "\n").filter { $0.contains(words) }
        expect(lines.count == 1, "\"\(words)\" should appear once: \(lines)")
        expect(lines.allSatisfy { $0.contains("] \(speaker)") }, "\"\(words)\" is not under \(speaker): \(lines)")
    }

    func clientTurnStartsWithFirstName(_ name: String) {
        expect(subject.text.contains("] \(name):"), "the client's turn does not start with \"\(name)\": \(subject.text.prefix(60))")
        expect(!subject.text.contains(Copy.callAudio), "the transcript still says \"\(Copy.callAudio)\"")
    }
}
