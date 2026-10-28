import XCTest

/// The Notes tab in the real app, driven with the scripted AI.
final class NoteUITests: AcceptanceCase {
    func test_NOTE_06_wholeLengthButtonOpensMenu() {
        given.aSession(transcript: SessionContent.shortTranscript)
        let tab = when.openNotesTab()

        when.clickLengthButtonAwayFromItsIcon(on: tab)

        then(tab).lengthMenuOffers(Copy.lengthChoices + Copy.effortChoices)
    }

    func test_NOTE_14_longSessionStepsThroughProcessingAndEndsWithCoverage() {
        given.aSession(transcript: SessionContent.longTranscript(), stageMs: 800)
        let tab = when.openNotesTab()
        tab.generateButton.click()

        then(tab).statusPasses(through: Copy.processingTranscript)
        then(tab.driver.waitFor(tab.coverage, timeout: 90) ? tab.coverageText : "").coverageCountsEveryPart()
    }

    func test_NOTE_17_detailedNoteCountsFollowUpLookups() {
        let coverage = generateLongNote(length: "detailed", effort: "normal")
        then(coverage).coverageCountsEveryPart()
        then(coverage).coverageCountsFollowUpLookups(true)
    }

    func test_NOTE_17_noteAtFocusCountsFollowUpLookups() {
        let coverage = generateLongNote(length: "natural", effort: "focus")
        then(coverage).coverageCountsFollowUpLookups(true)
    }

    func test_NOTE_17_detailedNoteAtFastCountsNone() {
        let coverage = generateLongNote(length: "detailed", effort: "fast")
        then(coverage).coverageCountsEveryPart()
        then(coverage).coverageCountsFollowUpLookups(false)
    }

    func test_NOTE_17_conciseNoteAtNormalCountsNone() {
        let coverage = generateLongNote(length: "concise", effort: "normal")
        then(coverage).coverageCountsFollowUpLookups(false)
    }

    func test_NOTE_17_naturalNoteAtNormalCountsNone() {
        let coverage = generateLongNote(length: "natural", effort: "normal")
        then(coverage).coverageCountsFollowUpLookups(false)
    }

    private func generateLongNote(length: String, effort: String) -> String {
        given.aSession(transcript: SessionContent.longTranscript(), length: length, effort: effort,
                       stageMs: 100, plansLookups: true)
        let tab = when.openNotesTab()
        return when.generateNote(on: tab)
    }
}
