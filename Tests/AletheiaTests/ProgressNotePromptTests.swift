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

    func testEveryFormatCarriesTheFormattingRules() {
        for format in ProgressNoteFormat.allCases {
            let prompt = Prompts.progressNote(format: format, transcript: transcript)
            XCTAssertTrue(prompt.contains(Prompts.noteFormattingRules), "\(format) should carry the formatting rules")
        }
        XCTAssertTrue(Prompts.noteFormattingRules.contains("blank line"))
        XCTAssertTrue(Prompts.noteFormattingRules.contains("Here is"))
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

    func testNilInstructionsUseTheDefault() {
        for format in ProgressNoteFormat.allCases {
            let prompt = Prompts.progressNote(format: format, transcript: transcript)
            XCTAssertTrue(prompt.contains(Prompts.defaultInstructions(for: format)), "\(format)")
        }
    }

    func testCustomInstructionsReplaceTheDefaultButKeepTheFixedParts() {
        for format in ProgressNoteFormat.allCases {
            let prompt = Prompts.progressNote(
                format: format,
                transcript: transcript,
                notes: "My note.",
                comments: ["A comment."],
                verbosity: .detailed,
                instructions: "CUSTOM INSTRUCTIONS"
            )
            XCTAssertTrue(prompt.contains("CUSTOM INSTRUCTIONS"))
            XCTAssertFalse(prompt.contains(Prompts.defaultInstructions(for: format)))
            XCTAssertTrue(prompt.contains(Prompts.transcriptLegend))
            XCTAssertTrue(prompt.contains(Prompts.noteFormattingRules))
            XCTAssertTrue(prompt.contains(SummaryVerbosity.clarityRule))
            XCTAssertTrue(prompt.contains(transcript))
            XCTAssertTrue(prompt.contains("My note."))
            XCTAssertTrue(prompt.contains("A comment."))
        }
    }

    func testStructuredDefaultsAskForSpecifics() {
        XCTAssertTrue(Prompts.defaultInstructions(for: .soap).contains("Avoid generic phrases"))
    }
}
