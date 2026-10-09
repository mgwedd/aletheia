import XCTest
@testable import Aletheia

/// Summary length setting: each level reaches the Summary prompt with the
/// clarity rule, and the structured formats are untouched by it.
final class SummaryVerbosityTests: XCTestCase {
    private let transcript = "[00:00] Call audio: I barely slept this week."

    func testDefaultIsNatural() {
        XCTAssertEqual(SummaryVerbosity.default, .natural)
        XCTAssertEqual(SummaryVerbosity.allCases, [.concise, .natural, .detailed])
    }

    func testEachLevelHasDistinctGuidanceAndLabels() {
        let guidance = Set(SummaryVerbosity.allCases.map(\.promptGuidance))
        XCTAssertEqual(guidance.count, 3)
        XCTAssertEqual(Set(SummaryVerbosity.allCases.map(\.displayName)), ["Concise", "Natural", "Detailed"])
        for level in SummaryVerbosity.allCases {
            XCTAssertFalse(level.blurb.isEmpty)
            XCTAssertEqual(SummaryVerbosity(rawValue: level.rawValue), level)
        }
    }

    func testSummaryPromptCarriesTheChosenLengthAndClarityRule() {
        for level in SummaryVerbosity.allCases {
            let prompt = Prompts.progressNote(format: .narrative, transcript: transcript, verbosity: level)
            XCTAssertTrue(prompt.contains(level.promptGuidance), "\(level) guidance missing")
            XCTAssertTrue(prompt.contains(SummaryVerbosity.clarityRule), "\(level) clarity rule missing")
            for other in SummaryVerbosity.allCases where other != level {
                XCTAssertFalse(prompt.contains(other.promptGuidance), "\(level) prompt carries \(other) guidance")
            }
        }
    }

    func testSummaryPromptDefaultsToNatural() {
        let prompt = Prompts.progressNote(format: .narrative, transcript: transcript)
        XCTAssertTrue(prompt.contains(SummaryVerbosity.natural.promptGuidance))
    }

    func testStructuredFormatsIgnoreTheSetting() {
        for format in ProgressNoteFormat.allCases where format != .narrative {
            let detailed = Prompts.progressNote(format: format, transcript: transcript, verbosity: .detailed)
            let concise = Prompts.progressNote(format: format, transcript: transcript, verbosity: .concise)
            XCTAssertEqual(detailed, concise, "\(format) should not vary with summary length")
            XCTAssertFalse(detailed.contains(SummaryVerbosity.clarityRule))
        }
    }

    func testLocalRequestPassesTheSettingThrough() {
        let request = LocalLLMRequest.progressNote(format: .narrative, transcript: "t", verbosity: .concise)
        XCTAssertTrue(request.prompt.contains(SummaryVerbosity.concise.promptGuidance))
    }
}
