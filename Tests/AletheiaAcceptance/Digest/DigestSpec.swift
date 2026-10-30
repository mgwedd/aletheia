import XCTest

final class DigestSpec: AcceptanceCase {
    func test_DIGEST_01() async throws {
        let model = SteeredModel()
        model.pausesOnTheFirstRequest()
        let summaries = try await given.summaries(model: model)
        for daysAgo in 0..<3 {
            try summaries.addLongSession(daysAgo: daysAgo)
        }
        summaries.startScheduler()
        summaries.openPatientPage()

        try await summaries.waitForFirstSummaryToBeInProgress()
        model.release()
        try await summaries.waitForRow("Summaries: all 3 ready")
        then(summaries.row).reads("Summaries: all 3 ready")
    }

    func test_DIGEST_02() async throws {
        let model = SteeredModel()
        model.readsPromptInParts(3, thenWrites: "Understood.", once: true)
        let summaries = try await given.summaries(model: model)
        let stored = try summaries.addLongSession()
        summaries.startScheduler()

        try await summaries.waitForTranscriptSteps(stored)
        then(summaries.transcriptStatus(of: stored)).showsProcessingWithAStepBar()
        model.letReadingFinish()
        try await summaries.waitForSummary(stored)
    }

    func test_DIGEST_03() async throws {
        let model = SteeredModel()
        model.pausesOnTheFirstRequest()
        let summaries = try await given.summaries(model: model)
        let stored = try summaries.addLongSession()
        summaries.startScheduler()
        try await summaries.waitForRow("Summaries: 0 of 1 ready")

        summaries.pressRowButton()
        then(summaries.row).offers(Copy.digestResume)
        try await summaries.recordAndStop(on: stored)
        model.release()

        try await summaries.waitForRowToRead(exactly: "Summaries: 0 of 1 ready · paused")
        then(summaries.row).offers(Copy.digestResume)
        then(summaries.alerts).showsAnAlertThatTranscriptionIsPaused()
    }

    func test_DIGEST_04() async throws {
        let summaries = try await given.summaries()
        let stored = try summaries.addLongSession()
        summaries.startScheduler()
        try await summaries.waitForSummary(stored)

        let edited = AssistantDesk.longTranscript(characters: 270_000)
        try summaries.editTranscript(of: stored, to: edited)
        try await summaries.waitForSummary(stored, transcript: edited)
    }

    func test_DIGEST_05() async throws {
        let model = SteeredModel()
        model.removesTheModelAfterTheFirstSection()
        let summaries = try await given.summaries(model: model)
        let stored = try summaries.addLongSession()
        summaries.startScheduler()

        try await summaries.waitForFailure(stored)
        then(summaries.transcriptStatus(of: stored)).showsFailure(Copy.digestCouldntBuild)
        then(summaries.transcriptStatus(of: stored)).offersRetry()
    }
}
