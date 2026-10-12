import XCTest
@testable import Aletheia

final class CallAudioDiagnosticsTests: XCTestCase {
    private func diagnostics(
        lastStart: CallAudioDiagnostics.StartResult = .started,
        disrupted: Bool = false,
        disruptions: Int = 0,
        firstFailure: String? = nil
    ) -> CallAudioDiagnostics {
        CallAudioDiagnostics(
            preflightGranted: false, currentBuild: "2.0+2", confirmedBuild: "2.0+1",
            attemptedThisLaunch: true, workedThisLaunch: false, lastStart: lastStart,
            streamRunning: !disrupted, streamDisrupted: disrupted, buffersReceived: 7,
            bytesWritten: nil, disruptions: disruptions, firstFailure: firstFailure)
    }

    func testAStartedUndisruptedStreamIsNotAProblem() {
        XCTAssertFalse(diagnostics().hasProblem)
        XCTAssertFalse(diagnostics(lastStart: .notTried).hasProblem)
    }

    func testSkippedFailedAndDisruptedAreProblems() {
        XCTAssertTrue(diagnostics(lastStart: .skipped).hasProblem)
        XCTAssertTrue(diagnostics(lastStart: .failed("x")).hasProblem)
        XCTAssertTrue(diagnostics(disrupted: true).hasProblem)
        // The stream's disrupted flag is cleared on stop; the count outlives it.
        XCTAssertTrue(diagnostics(disruptions: 1).hasProblem)
    }

    func testSummaryCarriesTheTriageFacts() {
        let summary = diagnostics(lastStart: .failed("SCStreamErrorDomain -3801")).summary
        XCTAssertTrue(summary.contains("Preflight granted: no"))
        XCTAssertTrue(summary.contains("Build: 2.0+2"))
        XCTAssertTrue(summary.contains("Grant confirmed for: 2.0+1"))
        XCTAssertTrue(summary.contains("Last start: failed: SCStreamErrorDomain -3801"))
        XCTAssertTrue(summary.contains("Buffers received: 7"))
        XCTAssertTrue(summary.contains("Bytes written: no file open"))
    }

    func testDescribeIsDomainAndCodeWithoutTheMessage() {
        let error = NSError(domain: "D", code: 42, userInfo: [NSLocalizedDescriptionKey: "/Users/x/Patients/Jane"])
        XCTAssertEqual(CallAudioDiagnostics.describe(error), "D 42")
    }

    func testSummaryLeavesOutTheFreeTextFailure() {
        let d = diagnostics(disruptions: 1, firstFailure: "couldn't write Jane-Doe.wav")
        XCTAssertFalse(d.summary.contains("Jane-Doe"))
        XCTAssertEqual(d.rows.last?.value, "couldn't write Jane-Doe.wav")
    }

    func testDoctorRowWarnsOnlyWhenThereIsAProblem() {
        XCTAssertTrue(DoctorRunner.callAudioChecks(nil).isEmpty)
        XCTAssertEqual(DoctorRunner.callAudioChecks(diagnostics()).first?.status, .ok)
        let skipped = DoctorRunner.callAudioChecks(diagnostics(lastStart: .skipped)).first
        XCTAssertEqual(skipped?.status, .warning)
        XCTAssertNotNil(skipped?.nextStep)
    }
}
