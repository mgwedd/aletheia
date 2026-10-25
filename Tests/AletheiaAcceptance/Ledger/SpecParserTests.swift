import XCTest

/// The doc parser and ledger report, exercised on small inline docs. These
/// stand in for the checks the coverage test makes on the real docs.
final class SpecParserTests: XCTestCase {
    private let goodCriteria = """
    # Acceptance criteria
    ## 1. Demo (DEMO)
    - **DEMO-01** Click Go → it goes.
    - **DEMO-02** Click Stop → it stops.
    ## 2. Other (OTHER)
    - **OTHER-01** Click Go → it goes.
    """

    private let goodReference = """
    - **DEM-001** Go goes.
      `surface: ui` · `evidence: src/A.swift:2` · `qa: DEMO-01`
    - **DEM-002** Stop stops.
      `surface: ui` · `qa: DEMO-02`
    - **OTH-001** Other goes.
      `surface: ui` · `qa: OTHER-01`
    """

    func test_goodDocsHaveNoProblems() {
        let criteria = SpecDocs.parseCriteria(goodCriteria)
        let reference = SpecDocs.parseReference(goodReference, knownChecks: criteria.ids)
        XCTAssertEqual(criteria.checks.map(\.id), ["DEMO-01", "DEMO-02", "OTHER-01"])
        XCTAssertEqual(criteria.journeys.map(\.prefix), ["DEMO", "OTHER"])
        XCTAssertEqual(criteria.checks.first?.sentence, "Click Go → it goes.")
        let tests = ["DEMO-01": 1, "DEMO-02": 1, "OTHER-01": 1]
        XCTAssertEqual(SpecDocs.coverageProblems(criteria: criteria, reference: reference, tests: tests), [])
    }

    func test_criteriaProblemsAreNamed() {
        let criteria = SpecDocs.parseCriteria("""
        ## 1. Demo (DEMO)
        - **DEMO-01** Click Go → it goes.
        - **DEMO-01** Click Again → it repeats.
        - **DEMO-02** Click Stop and see nothing.
        - **DEMO-03** Click → one → two.
        - **DEMO-9** Click Go → it goes.
        - **OTHER-01** Click Go → it goes.
        """)
        XCTAssertEqual(criteria.problems, [
            "DEMO-01: duplicate check ID",
            "DEMO-02: needs exactly one →",
            "DEMO-03: needs exactly one →",
            "malformed check line (want '- **ID-NN** do → see'): - **DEMO-9** Click Go → it goes.",
            "OTHER-01: sits under the (DEMO) heading",
        ])
    }

    func test_checkBeforeAnyHeadingIsMisfiled() {
        let criteria = SpecDocs.parseCriteria("- **DEMO-01** Click Go → it goes.")
        XCTAssertEqual(criteria.problems, ["DEMO-01: sits under the (no) heading"])
    }

    func test_referenceProblemsAreNamed() {
        let known: Set<String> = ["DEMO-01", "DEMO-02"]
        let reference = SpecDocs.parseReference("""
        - **DEM-001** Fine.
          `qa: DEMO-01`
        - **DEM-002** Stray.
          `qa: DEMO-99`
        - **DEM-003** Untagged.
          `surface: ui`
        - **DEM-001** Repeated.
          `qa: DEMO-01`
        - **DEM-004** Last line, no tags
        """, knownChecks: known)
        XCTAssertEqual(reference.problems, [
            "DEM-002: qa: DEMO-99 is not a check in the walkthrough",
            "DEM-003: no qa: tag",
            "DEM-001: duplicate reference ID",
            "DEM-004: no qa: tag",
        ])
        XCTAssertEqual(reference.rolledUp, ["DEMO-01"])
    }

    func test_coverageFlagsMissingStrayAndDuplicateTests() {
        let criteria = SpecDocs.parseCriteria(goodCriteria)
        let reference = SpecDocs.parseReference(
            "- **DEM-001** Go goes.\n  `qa: DEMO-01`\n", knownChecks: criteria.ids)
        let problems = SpecDocs.coverageProblems(
            criteria: criteria, reference: reference, tests: ["DEMO-01": 2, "DEMO-77": 1])
        XCTAssertEqual(problems, [
            "DEMO-02: no reference item rolls up to it",
            "OTHER-01: no reference item rolls up to it",
            "DEMO-02: no test_DEMO_02",
            "OTHER-01: no test_OTHER_01",
            "test_DEMO_01: defined 2 times",
            "test_DEMO_77 has no check in the walkthrough",
        ])
    }

    func test_unusedCopyEntriesAreFlagged() {
        let problems = SpecDocs.unusedCopyEntries(files: [
            "DSL/Copy.swift": "enum Copy {}",
            "Patient/PatientCopy.swift": "extension Copy { static let used = \"a\"; static let unused = \"b\" }",
            "Patient/PatientSpec.swift": "func test_PATIENT_01() { _ = Copy.used }",
        ])
        XCTAssertEqual(problems, ["Copy.unused is used by no test"])
    }

    func test_expectedFailuresAreFlagged() {
        let problems = SpecDocs.expectFailureProblems(files: [
            "A/ASpec.swift": "func test_A_01() { XCTExpectFailure(\"known\") }",
            "B/BSpec.swift": "func test_B_01() {}",
        ])
        XCTAssertEqual(problems, ["A/ASpec.swift: XCTExpectFailure; let a known defect fail"])
    }

    func test_fixedDelaysAreFlaggedOutsideEventually() {
        let sleeping = "func f() async throws { try await Task.sleep(nanoseconds: 1) }"
        let problems = SpecDocs.fixedDelayProblems(files: [
            "DSL/Eventually.swift": sleeping,
            "DSL/Given.swift": sleeping,
            "Drivers/InProcessDriver.swift": "Thread.sleep(forTimeInterval: 1)",
            "Patient/PatientSpec.swift": sleeping,
            "Drivers/Clean.swift": "func ok() {}",
        ])
        XCTAssertEqual(problems, [
            "DSL/Given.swift: fixed delay; wait with eventually(...) instead",
            "Drivers/InProcessDriver.swift: fixed delay; wait with eventually(...) instead",
        ])
    }

    func test_ledgerHeadlineCountsPassedOnly() throws {
        let criteria = SpecDocs.parseCriteria(goodCriteria)
        let ran = [
            "DEMO-01": LedgerEntry(id: "DEMO-01", status: .passed, sentence: "", message: nil),
            "DEMO-02": LedgerEntry(id: "DEMO-02", status: .failed, sentence: "", message: "expected X"),
        ]
        let entries = AcceptanceLedger.entries(ran: ran, criteria: criteria)
        XCTAssertEqual(entries.map(\.status), [.passed, .failed, .notRun])
        let markdown = LedgerReport.markdown(entries)
        XCTAssertTrue(markdown.contains("**Accepted: 1 of 3 checks**"), markdown)
        XCTAssertTrue(markdown.contains("- Failed (1): DEMO-02"), markdown)
        XCTAssertTrue(markdown.contains("- Not run (1): OTHER-01"), markdown)
        XCTAssertTrue(markdown.contains("expected X"), markdown)
        let json = try JSONSerialization.jsonObject(with: LedgerReport.json(entries)) as? [String: Any]
        XCTAssertEqual(json?["accepted"] as? Int, 1)
        XCTAssertEqual(json?["total"] as? Int, 3)
    }

    func test_pendingIsListedButNotAccepted() {
        let entries = [
            LedgerEntry(id: "A-01", status: .pending, sentence: "", message: "later"),
            LedgerEntry(id: "A-02", status: .passed, sentence: "", message: nil),
        ]
        let markdown = LedgerReport.markdown(entries)
        XCTAssertTrue(markdown.contains("**Accepted: 1 of 2 checks**"))
        XCTAssertTrue(markdown.contains("- Pending (1): A-01"))
    }
}
