import AVFoundation
import XCTest
@testable import Aletheia

/// Guards the status-mapping that the setup checklist and Settings status
/// section rely on: a granted permission must read as OK, and a status must
/// flip the moment the underlying grant changes (the "nothing updates" /
/// "doesn't read that perm is granted" regressions).
@MainActor
final class ToolHealthTests: XCTestCase {
    // MARK: Microphone

    func testMicrophoneAuthorizedIsOK() {
        XCTAssertEqual(ToolHealth.classifyMicrophone(.authorized).status, .ok)
    }

    func testMicrophoneDeniedAndRestrictedFail() {
        XCTAssertEqual(ToolHealth.classifyMicrophone(.denied).status, .failed)
        XCTAssertEqual(ToolHealth.classifyMicrophone(.restricted).status, .failed)
    }

    func testMicrophoneNotDeterminedIsWarning() {
        XCTAssertEqual(ToolHealth.classifyMicrophone(.notDetermined).status, .warning)
    }

    // MARK: Screen / call-audio capture

    func testScreenRecordingGrantedIsOK() {
        let check = ToolHealth.classifyScreenRecording(granted: true)
        XCTAssertEqual(check.status, .ok)
        XCTAssertEqual(check.kind, .screenRecording)
    }

    func testScreenRecordingDeniedFails() {
        XCTAssertEqual(ToolHealth.classifyScreenRecording(granted: false).status, .failed)
    }

    func testAGrantConfirmedInAnEarlierSessionStillReadsAsGranted() async {
        let name = "ToolHealthTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        CallAudioGrantStore(defaults: defaults, build: "1+1").confirm()

        let check = await ToolHealth.screenRecordingCheck(
            authoritative: false, grantStore: CallAudioGrantStore(defaults: defaults, build: "1+1"))

        XCTAssertEqual(check.status, .ok)
    }

    // MARK: Transcription model

    func testWhisperModelPresentIsOK() {
        XCTAssertEqual(ToolHealth.classifyWhisperModel(exists: true, modelDisplayName: "Small", sizeMB: 488).status, .ok)
    }

    func testWhisperModelMissingFailsAndNamesSize() {
        let check = ToolHealth.classifyWhisperModel(exists: false, modelDisplayName: "Small", sizeMB: 488)
        XCTAssertEqual(check.status, .failed)
        XCTAssertTrue(check.detail.contains("488"))
    }
}

final class ScreenAccessProbeGateTests: XCTestCase {
    func testOneArmBuysExactlyOneProbe() {
        _ = ScreenAccessProbeGate.consume() // start from a known state
        XCTAssertFalse(ScreenAccessProbeGate.consume(), "no probe without a user action")
        ScreenAccessProbeGate.arm()
        XCTAssertTrue(ScreenAccessProbeGate.consume())
        XCTAssertFalse(ScreenAccessProbeGate.consume(), "the probe is spent until armed again")
    }

    func testCheckIdentityIsStableAcrossRuns() {
        let a = ToolHealthCheck(kind: .microphone, title: "Microphone access", status: .ok, detail: "x")
        let b = ToolHealthCheck(kind: .microphone, title: "Microphone access", status: .ok, detail: "x")
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a, b)
    }
}


/// The whole readiness run, with the system's answers faked.
@MainActor
final class ToolHealthRunTests: XCTestCase {
    private struct NoAssistant: Assistant {
        func isReachable() async -> Bool { true }
        func listModels() async throws -> [String] { [] }
        func hasModel(_ name: String) async -> Bool { true }
        func generate(model: String, system: String, prompt: String) async throws -> String { "" }
        func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
    }

    private var suite: String!
    private var settings: AppSettings!
    private var folder: URL!

    override func setUp() {
        suite = "ToolHealthRunTests-\(UUID().uuidString)"
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        settings.dataRootURL = folder
    }

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func probes(
        microphone: AVAuthorizationStatus = .authorized,
        eventKit: EventKitAccess.Status = .granted,
        appleIntelligence: Bool = false,
        screenGranted: Bool = true,
        authoritativeSeen: ((Bool) -> Void)? = nil
    ) -> ToolHealth.Probes {
        var probes = ToolHealth.Probes()
        probes.microphoneStatus = { microphone }
        probes.eventKitStatus = { _ in eventKit }
        probes.appleIntelligenceAvailable = { appleIntelligence }
        probes.screenRecording = { authoritative in
            authoritativeSeen?(authoritative)
            return ToolHealth.classifyScreenRecording(granted: screenGranted)
        }
        return probes
    }

    private func run(
        backend: AssistantBackend = .localLlama,
        authoritative: Bool = true,
        includeScheduling: Bool = true,
        probes: ToolHealth.Probes
    ) async -> [ToolHealthCheck] {
        await ToolHealth.runAllChecks(
            settings: settings, backend: backend, assistant: NoAssistant(),
            authoritative: authoritative, includeScheduling: includeScheduling, probes: probes)
    }

    func testEveryToolIsReportedInSetupOrder() async {
        let checks = await run(probes: probes())
        XCTAssertEqual(checks.map(\.kind), [
            .termsAndPrivacy, .dataFolder, .microphone, .screenRecording, .whisperModel, .builtInModel,
            .calendar, .reminders,
        ])
        XCTAssertEqual(checks.first { $0.kind == .dataFolder }?.status, .ok)
        XCTAssertEqual(checks.first { $0.kind == .microphone }?.status, .ok)
        XCTAssertEqual(checks.first { $0.kind == .screenRecording }?.status, .ok)
        XCTAssertEqual(checks.first { $0.kind == .calendar }?.status, .ok)
        XCTAssertEqual(checks.first { $0.kind == .reminders }?.status, .ok)
    }

    func testCalendarAndRemindersAreLeftOutWhenTheBuildHasNoScheduling() async {
        let checks = await run(includeScheduling: false, probes: probes(eventKit: .denied))
        XCTAssertFalse(checks.contains { $0.kind == .calendar || $0.kind == .reminders })
        XCTAssertEqual(checks.count, 6)
    }

    func testDeniedPermissionsFailTheRequiredToolsButOnlyWarnForTheOptionalOnes() async {
        let checks = await run(probes: probes(microphone: .denied, eventKit: .denied, screenGranted: false))
        func status(_ kind: ToolHealthCheck.Kind) -> ToolHealthCheck.Status? { checks.first { $0.kind == kind }?.status }
        XCTAssertEqual(status(.microphone), .failed)
        XCTAssertEqual(status(.screenRecording), .failed)
        XCTAssertEqual(status(.calendar), .warning, "optional features never block readiness")
        XCTAssertEqual(status(.reminders), .warning)
    }

    func testAMissingDataFolderIsAFailureWithAnInstruction() async {
        settings.dataRootURL = nil
        let check = ToolHealth.dataFolderCheck(settings: settings)
        XCTAssertEqual(check.status, .failed)
        XCTAssertTrue(check.detail.contains("Settings"))
        let all = await run(probes: probes())
        XCTAssertEqual(all.first { $0.kind == .dataFolder }?.status, .failed)
    }

    func testTheChosenFolderIsNamedInItsCheck() {
        let check = ToolHealth.dataFolderCheck(settings: settings)
        XCTAssertEqual(check.status, .ok)
        XCTAssertEqual(check.detail, folder.path)
    }

    func testAPermissionGrantedBetweenRunsShowsOnTheNextRun() async {
        let before = await run(probes: probes(microphone: .denied, screenGranted: false))
        let after = await run(probes: probes(microphone: .authorized, screenGranted: true))
        XCTAssertEqual(before.first { $0.kind == .screenRecording }?.status, .failed)
        XCTAssertEqual(after.first { $0.kind == .screenRecording }?.status, .ok)
        XCTAssertEqual(before.first { $0.kind == .microphone }?.status, .failed)
        XCTAssertEqual(after.first { $0.kind == .microphone }?.status, .ok)
    }

    func testTheBackgroundPollIsNotAuthoritative() async {
        var seen: [Bool] = []
        _ = await run(authoritative: false, probes: probes(authoritativeSeen: { seen.append($0) }))
        _ = await run(authoritative: true, probes: probes(authoritativeSeen: { seen.append($0) }))
        XCTAssertEqual(seen, [false, true])
    }

    func testAppleIntelligenceBackendReportsItsOwnAvailability() async {
        let ready = await ToolHealth.assistantCheck(
            settings: settings, backend: .appleIntelligence, assistant: NoAssistant(), appleIntelligenceAvailable: true)
        let unavailable = await ToolHealth.assistantCheck(
            settings: settings, backend: .appleIntelligence, assistant: NoAssistant(), appleIntelligenceAvailable: false)
        XCTAssertEqual(ready.kind, .appleIntelligence)
        XCTAssertEqual(ready.status, .ok)
        XCTAssertEqual(unavailable.kind, .appleIntelligence)
        XCTAssertEqual(unavailable.status, .failed)
    }

    func testTheBuiltInEngineIsCheckedForTheOtherBackends() async {
        for backend in [AssistantBackend.localLlama, .automatic] {
            let check = await ToolHealth.assistantCheck(
                settings: settings, backend: backend, assistant: NoAssistant(), appleIntelligenceAvailable: true)
            XCTAssertEqual(check.kind, .builtInModel, "\(backend)")
        }
    }

    func testOptionalAccessStatusesMapToOkOrWarningNeverFailed() {
        XCTAssertEqual(ToolHealth.calendarCheck(status: .granted).status, .ok)
        XCTAssertEqual(ToolHealth.remindersCheck(status: .granted).status, .ok)
        for status in [EventKitAccess.Status.notDetermined, .denied, .unavailable] {
            XCTAssertEqual(ToolHealth.calendarCheck(status: status).status, .warning)
            XCTAssertEqual(ToolHealth.remindersCheck(status: status).status, .warning)
        }
        XCTAssertTrue(ToolHealth.calendarCheck(status: .denied).detail.contains("Schedule Next Session"))
        XCTAssertTrue(ToolHealth.remindersCheck(status: .denied).detail.contains("Remind Me"))
        XCTAssertEqual(ToolHealth.calendarCheck(status: .granted).kind, .calendar)
        XCTAssertEqual(ToolHealth.remindersCheck(status: .granted).kind, .reminders)
    }
}
