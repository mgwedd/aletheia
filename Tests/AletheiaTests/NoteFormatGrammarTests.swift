import XCTest
@testable import Aletheia

/// GBNF grammar generation is pure and derived from `ProgressNoteFormat.sections`,
/// so its structural contract — a rule per section, headings in order, and the
/// `##`-free `body` invariant that makes the note parse back cleanly — is tested
/// here without any model. On-device acceptance by the llama.cpp runtime is
/// verified at the pin/wiring step (the LLM epic); these tests pin the shape.
final class NoteFormatGrammarTests: XCTestCase {
    /// The structured formats that carry a grammar (narrative is excluded).
    private let structured: [ProgressNoteFormat] = [.soap, .dap, .birp, .girp]

    // MARK: Presence

    func testNarrativeHasNoGrammar() {
        XCTAssertNil(ProgressNoteFormat.narrative.grammar)
    }

    func testStructuredFormatsHaveGrammarLabeledByShortName() {
        for format in structured {
            let grammar = format.grammar
            XCTAssertNotNil(grammar, "\(format) should have a grammar")
            XCTAssertEqual(grammar?.label, format.shortName)
        }
    }

    // MARK: Structure

    func testGrammarHasRootAndBodyRules() {
        for format in structured {
            let gbnf = format.grammar!.gbnf
            XCTAssertTrue(gbnf.contains("root ::= "), "\(format) missing root rule")
            XCTAssertTrue(gbnf.contains("body ::= "), "\(format) missing body rule")
        }
    }

    func testRootReferencesEverySectionRule() {
        for format in structured {
            let gbnf = format.grammar!.gbnf
            let rootLine = gbnf.split(separator: "\n").first { $0.hasPrefix("root ::=") }
            XCTAssertNotNil(rootLine, "\(format) missing root line")
            for index in format.sections.indices {
                XCTAssertTrue(rootLine!.contains("sec\(index)"),
                              "\(format) root must reference sec\(index)")
            }
        }
    }

    func testHeadingsAppearInSectionOrder() {
        for format in structured {
            let gbnf = format.grammar!.gbnf
            var searchStart = gbnf.startIndex
            for section in format.sections {
                let marker = "## \(section.heading)\\n"
                guard let range = gbnf.range(of: marker, range: searchStart..<gbnf.endIndex) else {
                    return XCTFail("\(format) grammar missing \(marker) in order")
                }
                searchStart = range.upperBound
            }
        }
    }

    /// The core invariant: the only `##` in the grammar are the section headings,
    /// so a note the grammar produces can only carry `##` at a real heading.
    func testOnlyHeadingsIntroduceDoubleHash() {
        for format in structured {
            let gbnf = format.grammar!.gbnf
            let doubleHashes = gbnf.components(separatedBy: "## ").count - 1
            XCTAssertEqual(doubleHashes, format.sections.count,
                           "\(format): every `## ` must be a heading, none in body")
        }
    }

    func testBodyRuleForbidsDoubleHash() {
        for format in structured {
            let gbnf = format.grammar!.gbnf
            let bodyLine = gbnf.split(separator: "\n").first { $0.hasPrefix("body ::=") }!
            // The body alternation allows a lone '#' but never two in a row.
            XCTAssertTrue(bodyLine.contains("[^#]"), "\(format) body must exclude '#'")
            XCTAssertFalse(bodyLine.contains("##"), "\(format) body must not allow '##'")
        }
    }

    // MARK: Determinism

    func testGrammarIsDeterministicPerFormat() {
        for format in structured {
            XCTAssertEqual(format.grammar, format.grammar)
        }
        XCTAssertNotEqual(ProgressNoteFormat.soap.grammar, ProgressNoteFormat.dap.grammar)
    }

    // MARK: GIRP (the newly added format)

    func testGirpSectionsAreGoalInterventionResponsePlan() {
        XCTAssertEqual(ProgressNoteFormat.girp.sections.map(\.heading),
                       ["Goal", "Intervention", "Response", "Plan"])
    }

    func testGirpGrammarOpensWithGoal() {
        let gbnf = ProgressNoteFormat.girp.grammar!.gbnf
        XCTAssertTrue(gbnf.contains("sec0 ::= \"## Goal\\n\" body"),
                      "GIRP's first section must be Goal")
    }

    // MARK: Request assembly (the plumbing the engine uses)

    func testProgressNoteRequestCarriesFormatGrammarAndIsDeterministic() {
        let req = LocalLLMRequest.progressNote(format: .soap, transcript: "t")
        XCTAssertEqual(req.grammar, ProgressNoteFormat.soap.grammar)
        XCTAssertEqual(req.sampling, .deterministic)
        XCTAssertEqual(req.prompt, Prompts.progressNote(format: .soap, transcript: "t"))
    }

    func testNarrativeRequestHasNoGrammar() {
        let req = LocalLLMRequest.progressNote(format: .narrative, transcript: "t")
        XCTAssertNil(req.grammar)
    }
}
