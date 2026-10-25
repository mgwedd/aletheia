import XCTest
@testable import Aletheia

@MainActor
private final class SystemFake: SetupSystem {
    var folder: URL?
    var microphoneAnswer = true
    var callAudioAnswer = false
    var grantedAfterChecks = 0
    private(set) var checks = 0
    private(set) var log: [String] = []

    func chooseFolder() -> URL? { log.append("pick folder"); return folder }
    func requestMicrophone() async -> Bool { log.append("microphone prompt"); return microphoneAnswer }
    func openMicrophoneSettings() { log.append("microphone settings") }
    func requestCallAudio() async -> Bool { log.append("call audio prompt"); return callAudioAnswer }
    func callAudioGranted() -> Bool { checks += 1; return checks >= grantedAfterChecks }
    func openCallAudioSettings() { log.append("call audio settings") }
    func armCallAudioProbe() { log.append("arm") }
    func confirmCallAudioGrant() { log.append("confirm") }
}

@MainActor
final class SetupActionRunnerTests: XCTestCase {
    private func runner(_ system: SystemFake, settings: AppSettings) -> SetupActionRunner {
        SetupActionRunner(system: system, settings: settings, rebuildStore: {}, pollInterval: 0, maxPolls: 5)
    }

    private func withSettings(_ body: (AppSettings) async throws -> Void) async rethrows {
        let suite = "setup-runner-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(AppSettings(defaults: defaults))
    }

    func testMicrophoneButtonsAskThenOpenSettings() async throws {
        let system = SystemFake()
        try await withSettings { settings in
            let run = runner(system, settings: settings)
            let askedFor = try await run.perform(.requestMicrophone)
            let openedSettings = try await run.perform(.openMicrophoneSettings)
            XCTAssertTrue(askedFor && openedSettings)
        }
        XCTAssertEqual(system.log, ["microphone prompt", "microphone settings"])
    }

    func testCallAudioGrantedAtThePromptIsConfirmedWithoutOpeningSettings() async throws {
        let system = SystemFake()
        system.callAudioAnswer = true
        try await withSettings { settings in
            _ = try await runner(system, settings: settings).perform(.requestScreenRecording)
        }
        XCTAssertEqual(system.log, ["call audio prompt", "confirm"])
    }

    func testCallAudioGrantedInSystemSettingsIsSeenWhileWaiting() async throws {
        let system = SystemFake()
        system.grantedAfterChecks = 3
        try await withSettings { settings in
            _ = try await runner(system, settings: settings).perform(.requestScreenRecording)
        }
        XCTAssertEqual(system.log, ["call audio prompt", "arm", "call audio settings"])
        XCTAssertEqual(system.checks, 3, "stops looking once the grant is seen")
    }

    func testWaitingForACallAudioGrantGivesUpQuietly() async throws {
        let system = SystemFake()
        system.grantedAfterChecks = 100
        try await withSettings { settings in
            let seen = await runner(system, settings: settings).waitForCallAudioGrant()
            XCTAssertFalse(seen)
        }
        XCTAssertEqual(system.checks, 5)
    }

    func testChoosingAFolderSetsItAndRebuildsTheStore() async throws {
        let system = SystemFake()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runner-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        system.folder = folder
        var rebuilt = 0
        try await withSettings { settings in
            let run = SetupActionRunner(system: system, settings: settings, rebuildStore: { rebuilt += 1 }, pollInterval: 0, maxPolls: 1)
            _ = try await run.perform(.chooseFolder)
            XCTAssertEqual(settings.dataRootURL?.standardizedFileURL.path, folder.standardizedFileURL.path)
        }
        XCTAssertEqual(rebuilt, 1)
    }

    func testOtherActionsAreLeftToTheCaller() async throws {
        let system = SystemFake()
        try await withSettings { settings in
            let handled = try await runner(system, settings: settings).perform(.downloadBuiltInModel)
            XCTAssertFalse(handled)
        }
        XCTAssertTrue(system.log.isEmpty)
    }
}
