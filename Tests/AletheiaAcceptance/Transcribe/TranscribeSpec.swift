import XCTest

final class TranscribeSpec: AcceptanceCase {
    private let intake: [(speaker: String, at: TimeInterval, text: String)] = [
        ("You", 5, "How have you been sleeping?"),
        ("Call audio", 9, "A little better this week."),
    ]

    func test_TRANSCRIBE_01() async throws {
        let desk = try given.transcriptionDesk(speechModel: .notDownloaded)
        let session = try desk.recordSession(of: try await given.patient(named: "Jane Doe"))

        let result = try await desk.transcribe(session)

        then(result).failedSaying(Copy.downloadSpeechModelFirst)
        then(result).leftNoTranscript()
        then(result).keptTheRecording()
    }

    func test_TRANSCRIBE_02() async throws {
        let desk = try given.transcriptionDesk(speechModel: .ready)
        let session = try desk.recordSession(of: try await given.patient(named: "Jane Doe"))
        try desk.pressTranscribe(session)

        try await desk.modelReports(0.2, in: .preparingAudio)
        then(desk.band(of: session)).showsStage(Copy.preparingAudio)
        then(desk.band(of: session)).showsPercent(20)

        try await desk.modelReports(0.6)
        then(desk.band(of: session)).showsStage(Copy.transcribingMic)
        then(desk.band(of: session)).showsPercent(60)

        try await desk.modelReports(0.4)
        then(desk.band(of: session)).showsPercent(60)

        try await desk.modelReports(0.8)
        then(desk.band(of: session)).showsPercent(80)

        desk.modelWillHear(intake)
        then(try await desk.waitForResult(of: session)).finishedNormally()
    }

    func test_TRANSCRIBE_03() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        let desk = try given.transcriptionDesk(speechModel: .ready)
        let first = try desk.recordSession(of: jane, daysAgo: 2)
        let second = try desk.recordSession(of: jane, daysAgo: 1)
        let third = try desk.recordSession(of: jane)

        try desk.pressTranscribe(first)
        try await desk.modelReports(0.1)
        try desk.pressTranscribe(second)
        try desk.pressTranscribe(third)

        then(desk.band(of: first)).isTranscribing()
        then(desk.band(of: second)).isWaitingForItsTurn()
        then(desk.band(of: third)).isWaitingForItsTurn()

        desk.pressCancel(third)
        then(desk.band(of: third)).isNotTranscribing()

        desk.modelWillHear(intake)
        desk.modelWillHear(intake)
        then(try await desk.waitForResult(of: first)).savedATranscript()
        then(try await desk.waitForResult(of: second)).savedATranscript()
        then(desk.band(of: third)).isNotTranscribing()
    }

    func test_TRANSCRIBE_04() async throws {
        let desk = try given.transcriptionDesk(speechModel: .ready)
        let session = try desk.recordSession(of: try await given.patient(named: "Jane Doe"))
        try desk.pressTranscribe(session)

        try await desk.modelReports(0.4)

        then(desk.band(of: session)).isTranscribing()
        then(desk.band(of: session)).menuBarShows("Transcribing… 40%")

        desk.modelWillHear(intake)
        then(try await desk.waitForResult(of: session)).savedATranscript()
    }

    func test_TRANSCRIBE_05() async throws {
        let desk = try given.transcriptionDesk(speechModel: .ready)
        let session = try desk.recordSession(of: try await given.patient(named: "Jane Doe"))
        try desk.pressTranscribe(session)
        try await desk.modelReports(0.3)

        desk.pressCancel(session)
        let result = try await desk.waitForResult(of: session)

        then(result).wasCancelled()
        then(result).leftNoTranscript()
        then(result).keptTheRecording()
        then(result).sentNoNotification(titled: Copy.transcriptReady)
    }

    func test_TRANSCRIBE_06() async throws {
        let desk = try given.transcriptionDesk(speechModel: .ready)
        let session = try desk.recordSession(of: try await given.patient(named: "Jane Doe"))
        try desk.pressTranscribe(session)
        try await desk.modelReports(0.3)

        try await desk.quitAndReopen()
        desk.modelWillHear(intake)
        let result = try await desk.waitForResult(of: session)

        then(result).finishedNormally()
        then(result).savedATranscript()
    }

    func test_TRANSCRIBE_07() async throws {
        let desk = try given.transcriptionDesk(speechModel: .ready)
        let session = try desk.recordSession(of: try await given.patient(named: "Jane Doe"))
        desk.modelWillHear(intake)

        _ = try await desk.transcribe(session)
        let reading = try desk.readTranscript(of: session)

        then(reading).linesAreTimeStamped()
        then(reading).hasLine("00:05", from: "You", saying: "How have you been sleeping?")
        then(reading).hasLine("00:09", from: "Jane", saying: "A little better this week.")
        then(reading).neverNamesSpeaker("Call audio")
    }

    func test_TRANSCRIBE_08() async throws {
        let desk = try given.transcriptionDesk(speechModel: .ready)
        let session = try desk.recordSession(of: try await given.patient(named: "Jane Doe"))
        then(try desk.onDisk(session)).hasRecording()
        desk.modelWillHear(intake)

        let result = try await desk.transcribe(session)

        then(result).savedATranscript()
        then(result).deletedTheRecording()
    }

    func test_TRANSCRIBE_09() async throws {
        let desk = try given.transcriptionDesk(speechModel: .ready)
        let session = try desk.recordSession(of: try await given.patient(named: "Jane Doe"))
        desk.modelWillHearNothing()

        let result = try await desk.transcribe(session)

        then(result).saysNoSpeechWasDetected()
        then(result).keptTheRecording()
        then(result).leftNoTranscript()
        then(result).sentNotification(titled: Copy.transcriptionNeedsAttention)
    }

    func test_TRANSCRIBE_10() async throws {
        try pending("UI driver: the edit bar's Save and Discard buttons and the ⌘S shortcut live in the session view")
    }

    func test_TRANSCRIBE_11() async throws {
        try pending("UI driver: the \"Save your transcript edits?\" dialog and its three buttons live in the session view")
    }

    func test_TRANSCRIBE_12() async throws {
        let desk = try given.transcriptionDesk(speechModel: .ready)
        let session = try desk.recordSession(of: try await given.patient(named: "Jane Doe"))
        try desk.turnOnEncryption()
        desk.keepRawAudioAfterTranscription()
        desk.modelWillHear(intake)

        let result = try await desk.transcribe(session)

        then(result).savedATranscript()
        then(result).keptTheRecording()
        then(desk).rawAudioIsNotReadableOnDisk()
    }

    func test_TRANSCRIBE_13() async throws {
        let desk = try given.transcriptionDesk(speechModel: .damaged)
        let session = try desk.recordSession(of: try await given.patient(named: "Jane Doe"))

        let result = try await desk.transcribe(session)

        then(result).failedSaying(Copy.speechModelDamaged)
        then(result).sentNotification(titled: Copy.transcriptionNeedsAttention)
        then(result).keptTheRecording()
    }

    func test_TRANSCRIBE_14() async throws {
        let desk = try given.transcriptionDesk(speechModel: .ready)
        let session = try desk.recordSession(of: try await given.patient(named: "Jane Doe"))
        try desk.pressTranscribe(session)
        try await desk.modelReports(0.5)
        desk.modelFails(saying: "The audio could not be read.")

        let result = try await desk.waitForResult(of: session)

        then(result).failedWith(reasonContaining: "The audio could not be read.")
        then(result).leftNoTranscript()
        then(result).keptTheRecording()
        then(result).sentNotification(titled: Copy.transcriptionNeedsAttention)
    }

    func test_TRANSCRIBE_15() async throws {
        let desk = try given.transcriptionDesk(speechModel: .ready)
        let session = try desk.recordSession(of: try await given.patient(named: "Jane Doe"))
        try desk.turnOnEncryption()
        desk.modelWillHear(intake)

        let result = try await desk.transcribe(session)

        then(result).savedATranscript()
        then(desk).isNotReadableOnDisk("How have you been sleeping?")
    }

    func test_TRANSCRIBE_16() async throws {
        let desk = try given.transcriptionDesk(speechModel: .ready)
        let session = try desk.recordSession(of: try await given.patient(named: "Jane Doe"))
        desk.keepRawAudioAfterTranscription()
        desk.modelWillHear(intake)

        let result = try await desk.transcribe(session)

        then(result).savedATranscript()
        then(result).deletedTheRecording()
    }

    func test_TRANSCRIBE_17() async throws {
        let desk = try given.transcriptionDesk(speechModel: .ready)
        let session = try desk.recordSession(of: try await given.patient(named: "Jane Doe"))
        let earlier = "[00:05] You: Earlier session text"
        try desk.alreadyTranscribed(session, as: earlier)
        desk.modelWillHearNothing()

        let result = try await desk.transcribe(session)

        then(result).saysNoSpeechWasDetected()
        then(result).keptTheExistingTranscript(earlier)
        then(result).keptTheRecording()
    }

    func test_TRANSCRIBE_18() async throws {
        try pending("the one-time notice that raw audio was deleted after transcription isn't built yet (TRN-092)")
    }
}
