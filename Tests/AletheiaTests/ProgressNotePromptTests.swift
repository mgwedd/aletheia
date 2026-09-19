import XCTest
@testable import Aletheia

final class ProgressNotePromptTests: XCTestCase {
    private let transcript = "[00:00] Client: I barely slept this week."

    func testStructuredPromptNamesEverySectionAsHeading() {
        let prompt = Prompts.progressNote(format: .soap, transcript: transcript)
        for heading in ProgressNoteFormat.soap.sections.map(\.heading) {
            XCTAssertTrue(prompt.contains("## \(heading)"), "prompt should ask for a '## \(heading)' section")
        }
        XCTAssertTrue(prompt.contains(transcript))
    }

    func testStructuredPromptCarriesGroundingRules() {
        let prompt = Prompts.progressNote(format: .dap, transcript: transcript)
        XCTAssertTrue(prompt.contains("Never invent"))
        XCTAssertTrue(prompt.contains("Not documented in this session."))
    }

    func testNarrativePromptHasNoMarkdownHeadings() {
        let prompt = Prompts.progressNote(format: .narrative, transcript: transcript)
        XCTAssertFalse(prompt.contains("## "))
        XCTAssertTrue(prompt.contains(transcript))
    }

    func testTherapistNotesAndCommentsAppearInPrompt() {
        let prompt = Prompts.progressNote(
            format: .birp,
            transcript: transcript,
            notes: "Discussed sleep hygiene.",
            comments: ["- On “barely slept”: recurring theme"]
        )
        XCTAssertTrue(prompt.contains("Discussed sleep hygiene."))
        XCTAssertTrue(prompt.contains("recurring theme"))
    }

    func testNarrativeFoldsInTherapistMaterial() {
        let prompt = Prompts.progressNote(
            format: .narrative,
            transcript: transcript,
            notes: "Client is making progress."
        )
        XCTAssertTrue(prompt.contains("Client is making progress."))
    }
}
