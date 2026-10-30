import XCTest

/// The summaries row, the Transcript tab's build status and the editing of a summarized transcript, in the real app.
final class DigestUITests: AcceptanceCase {
    func test_DIGEST_01_rowCountsReadySummaries() {
        given.aLongSession(stageMs: 800)
        let screen = when.openSummaries()

        XCTAssertTrue(screen.driver.waitFor(screen.row, timeout: 30))
        XCTAssertTrue(screen.rowText.contains("Summaries: 0 of 1 ready"), screen.rowText)
        XCTAssertTrue(screen.driver.waitFor(screen.driver.element(labelContaining: Copy.digestAllReady), timeout: 90))
    }

    func test_DIGEST_02_transcriptShowsProcessingWhileSummaryBuilds() {
        given.aLongSession(stageMs: 800)
        let screen = when.openSummaries()
        when.openTranscriptTab(screen)

        XCTAssertTrue(screen.driver.waitFor(screen.processing, timeout: 30))
    }

    func test_DIGEST_03_pauseIsSaidInTheRow() {
        given.aLongSession(stageMs: 800)
        let screen = when.openSummaries()

        XCTAssertTrue(screen.driver.waitFor(screen.pauseButton, timeout: 30))
        screen.pauseButton.click()
        XCTAssertTrue(screen.driver.waitFor(screen.resumeButton, timeout: 10))
        XCTAssertTrue(screen.rowText.contains(Copy.digestPausedWords), screen.rowText)
    }

    func test_DIGEST_04_editedTranscriptIsSummarizedAgain() {
        given.aLongSession()
        let screen = when.openSummaries()
        when.openTranscriptTab(screen)
        XCTAssertTrue(screen.driver.waitFor(screen.driver.element(labelContaining: Copy.digestAllReady), timeout: 90))
        when.editTranscript(screen, adding: "An extra line added by the edit.")

        XCTAssertTrue(screen.driver.waitFor(screen.driver.element(labelContaining: Copy.processingTranscript), timeout: 30))
    }

    func test_DIGEST_05_failedBuildOffersRetry() {
        given.aLongSession(modelMissing: true)
        let screen = when.openSummaries()
        when.openTranscriptTab(screen)

        XCTAssertTrue(screen.driver.waitFor(screen.failure, timeout: 60))
        XCTAssertTrue(screen.driver.waitFor(screen.retryButton, timeout: 10))
    }
}
