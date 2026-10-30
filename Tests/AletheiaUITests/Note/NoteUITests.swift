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

    func test_NOTE_01_pickerOffersFormatsAndMyNotes() {
        given.aSession(transcript: SessionContent.shortTranscript)
        let tab = when.openNotesTab()

        then(tab).pickerOffers(["Summary", "SOAP", "DAP", "BIRP", "GIRP", Copy.myNotes])
    }

    func test_NOTE_02_emptySoapPaneOffersGenerate() {
        given.aSession(transcript: SessionContent.shortTranscript)
        let tab = when.openNotesTab()

        when.pickFormat("SOAP", on: tab)

        then(tab).showsTheEmptySoapNote()
    }

    func test_NOTE_03_generatingShowsStatusWithElapsedTimeAndStop() {
        given.aSession(transcript: SessionContent.shortTranscript, stageMs: 300, replies: [
            "Subjective: The client felt tired and anxious about work deadlines this week and wanted to talk through sleep."
        ], streamsWords: true)
        let tab = when.openNotesTab()
        when.pickFormat("SOAP", on: tab)

        tab.generateSoapButton.click()

        then(tab).showsStatusWithElapsedTimeAndStop()
        then(tab).showsText("Subjective: The client felt tired")
    }

    func test_NOTE_04_soapNoteHasSectionsAndSpeakerNames() {
        given.aSession(transcript: SessionContent.shortTranscript, replies: [Copy.soapReply])
        let tab = when.openNotesTab()
        when.pickFormat("SOAP", on: tab)

        let text = when.generateNote(on: tab, until: "Follow up next week.")

        then(text).hasTheSoapSections()
    }

    func test_NOTE_05_stopKeepsTextWrittenSoFar() {
        given.aSession(transcript: SessionContent.shortTranscript, stageMs: 300, replies: [
            "Subjective: The client said she has been waking at four most nights and that the deadlines keep her up. More words follow here to keep it streaming for a while."
        ], streamsWords: true)
        let tab = when.openNotesTab()
        when.pickFormat("SOAP", on: tab)
        tab.generateSoapButton.click()
        then(tab).showsText("Subjective: The client said")

        tab.driver.button(Copy.stop).click()

        then(tab).stopIsGone()
        then(tab).showsText("Subjective: The client said")
    }

    func test_NOTE_07_editPromptSheetSavesAndResets() {
        given.aSession(transcript: SessionContent.shortTranscript)
        let tab = when.openNotesTab()
        when.pickFormat("SOAP", on: tab)

        tab.lengthButton.click()
        tab.menuItem(startingWith: Copy.soapPromptEdit).click()
        let field = tab.driver.app.textViews[Copy.soapPromptSheet].firstMatch
        XCTAssertTrue(tab.driver.exists(field), "the SOAP prompt sheet has no instructions field")
        field.click()
        field.typeText(" Keep it to five sentences.")
        tab.driver.button(Copy.save).click()

        tab.lengthButton.click()
        tab.menuItem(startingWith: Copy.soapPromptEdit).click()
        XCTAssertTrue(tab.driver.exists(tab.driver.button(Copy.resetToDefault)), "no Reset to Default")
        tab.driver.button(Copy.resetToDefault).click()
        let restored = tab.driver.app.textViews[Copy.soapPromptSheet].firstMatch
        XCTAssertFalse((restored.value as? String ?? "").contains("Keep it to five sentences."),
                       "Reset to Default kept the custom instructions")
    }

    func test_NOTE_08_noteWaitsForChatAnswerWithCancel() {
        given.aSessionToAskAbout(replies: ["The client answered."], stageMs: 3000)
        let ask = when.openAskTab()
        when.ask("What did she say about sleep?", on: ask)
        let tab = when.openNotesTab()

        tab.generateButton.click()

        then(tab).isWaitingForChat()
    }

    func test_NOTE_09_missingModelAlertOffersDownload() {
        given.aSession(transcript: SessionContent.shortTranscript, modelMissing: true)
        let tab = when.openNotesTab()

        tab.generateButton.click()

        then(tab).showsTheNotDownloadedAlert()
    }

    func test_NOTE_10_regenerateAsksBeforeReplacingEditedNote() {
        given.aSession(transcript: SessionContent.shortTranscript, replies: [Copy.soapReply])
        let tab = when.openNotesTab()
        when.pickFormat("SOAP", on: tab)
        let generated = when.generateNote(on: tab, until: "Follow up next week.")
        XCTAssertFalse(generated.isEmpty)
        tab.driver.button(Copy.edit).click()
        tab.editor.click()
        tab.editor.typeText(" My own edit.")
        tab.driver.button(Copy.save).click()

        tab.driver.button(Copy.regenerate).click()

        then(tab).asksBeforeReplacing()
    }

    func test_NOTE_11_boldAndItalicShowFormattedWithoutSymbols() {
        given.aSession(transcript: SessionContent.shortTranscript, replies: [Copy.soapReply])
        let tab = when.openNotesTab()
        when.pickFormat("SOAP", on: tab)
        _ = when.generateNote(on: tab, until: "Follow up next week.")
        tab.driver.button(Copy.edit).click()

        tab.editor.click()
        tab.editor.typeText("Bold")
        tab.driver.app.typeKey("a", modifierFlags: .command)
        tab.driver.app.typeKey("b", modifierFlags: .command)
        tab.driver.app.typeKey("i", modifierFlags: .command)
        XCTAssertFalse((tab.editor.value as? String ?? "").contains("**"), "raw ** shows in the editor")
        tab.driver.button(Copy.save).click()

        XCTAssertFalse(tab.driver.anything(containing: "**").exists, "raw Markdown symbols show after Save")
    }

    func test_NOTE_13_myNotesSavesAsTypedAndSurvivesRelaunch() {
        given.aSession(transcript: SessionContent.shortTranscript)
        let tab = when.openNotesTab()
        tab.driver.button(Copy.myNotes).click()
        let editor = tab.driver.app.textViews.firstMatch
        editor.click()
        editor.typeText("Avoided the topic of her mother.")

        tab.driver.relaunch()

        let reopened = when.openNotesTab()
        reopened.driver.button(Copy.myNotes).click()
        then(reopened).showsText("Avoided the topic of her mother.")
    }

    func test_NOTE_15_copyPutsFormattedNoteOnClipboard() {
        given.aSession(transcript: SessionContent.shortTranscript, replies: [
            "## Plan\n\n- Review sleep\n- Breathing exercise\n\nFollow up next week."
        ])
        let tab = when.openNotesTab()
        when.pickFormat("SOAP", on: tab)
        _ = when.generateNote(on: tab, until: "Follow up next week.")

        tab.driver.button(Copy.copy).click()

        XCTAssertTrue(tab.driver.exists(tab.driver.button(Copy.copied)), "the button does not say Copied")
        let rtf = NSPasteboard.general.data(forType: .rtf) ?? Data()
        let rich = (try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))?.string ?? ""
        XCTAssertTrue(rich.contains("Review sleep") && rich.contains("•"), "the clipboard has no formatted list: \(rich)")
    }

    func test_NOTE_16_injectedLineIsNotObeyed() {
        given.aSession(
            transcript: "[00:05] Y: How was your week?\n[00:20] C: \(Copy.ignoredLine)",
            replies: [Copy.soapReply])
        let tab = when.openNotesTab()
        when.pickFormat("SOAP", on: tab)

        let text = when.generateNote(on: tab, until: "Follow up next week.")

        then(text).hasTheSoapSections()
    }

    private func generateLongNote(length: String, effort: String) -> String {
        given.aSession(transcript: SessionContent.longTranscript(), length: length, effort: effort,
                       stageMs: 100, plansLookups: true)
        let tab = when.openNotesTab()
        return when.generateNote(on: tab)
    }
}
