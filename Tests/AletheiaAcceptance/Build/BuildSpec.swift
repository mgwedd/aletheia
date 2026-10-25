import XCTest

final class BuildSpec: AcceptanceCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = true
    }

    func test_BUILD_01() async throws {
        // The entitlements project.yml signs the Release app with; the
        // codesign output itself needs a built Release app.
        let entitlements = try when.readReleaseEntitlements(of: .app)

        then(entitlements).areExactly([
            "com.apple.security.app-sandbox",
            "com.apple.security.device.audio-input",
            "com.apple.security.files.user-selected.read-write"
        ])
        then(entitlements).includeNoNetworkClient()
    }

    func test_BUILD_02() async throws {
        let entitlements = try when.readReleaseEntitlements(of: .networkHelper)

        then(entitlements).areExactly([
            "com.apple.security.app-sandbox",
            "com.apple.security.network.client"
        ])
    }

    func test_BUILD_03() async throws {
        // The Release Info.plist is the template with developer-only blocks
        // left out; the plutil output itself needs a built Release app.
        let info = try when.readReleaseInfoPlist()

        then(info).explainsMicrophoneAndSpeech()
        then(info).asksForNeitherCalendarNorReminders()
        then(info).versionMatchesSettings(when.settingsVersion())
    }

    func test_BUILD_04() async throws {
        // Partial: the Release binary is not built here, so this reads the
        // source it is built from.
        then(when.readAppSource()).keepsTheRecordingHarnessOutOfRelease()
    }

    func test_BUILD_05() async throws {
        // Partial: the app bundle under test is the Debug build, which carries
        // the same runtimes as Release.
        let bundle = when.listBundleContents()

        then(bundle).holdsOnlySpeechAndLanguageRuntimes()
        then(bundle).holdsNoAnalyticsSDK()
        then(bundle).holdsNoModelFiles()
    }

    func test_BUILD_06() async throws {
        // Partial: which features the Release build composes. Help, Settings
        // and Shortcuts are drawn by views and need a UI driver.
        given.buildIs(.release)

        then(when.featuresInThisBuild()).ships(["doctor", "embeddedLlama"])
        then(when.featuresInThisBuild()).doesNotShip(["atRestEncryption", "spotlightIndexing", "eventKitScheduling", "appIntents"])
    }

    func test_BUILD_07() async throws {
        try pending("seam: nettop needs a running Release app and a process-level network observer; no driver launches the app and watches its sockets")
    }

    func test_BUILD_08() async throws {
        try pending("seam: nettop needs a running Release app that checks for updates and downloads a model; the helper's calls are fixed assets with no injectable network")
    }

    func test_BUILD_09() async throws {
        let model = try when.downloadModel()
        then(model).matchesItsPinnedChecksum()

        let damaged = try when.cutShort(model)
        then(damaged).isRefused()
    }

    func test_BUILD_10() async throws {
        let bench = try given.recordingBench()
        defer { bench.cleanUp() }
        let visit = try await given.aPatientWithASession()
        await when.pressRecord(on: bench, visit)
        await when.stop(on: bench)

        then(when.listPatientFolders()).areNamedByUUIDAndDateWithOnlyAudioAndText()
    }

    func test_BUILD_11() async throws {
        let bench = try given.recordingBench()
        defer { bench.cleanUp() }
        let visit = try await given.aPatientWithASession()

        await when.pressRecord(on: bench, visit)

        then(when.listSessionFolder(of: visit, bench: bench)).hasNoAudio()

        await when.stop(on: bench)
        then(bench).savedBothFiles(when.files(of: visit, bench: bench))
    }

    func test_BUILD_12() async throws {
        let receipt = try when.acceptTermsAndReadReceipt()

        then(receipt).holdsOneLineWithVersionTimeAndAppVersion()
    }

    func test_BUILD_13() async throws {
        try pending("seam: the scripts need a shell outside the sandboxed test host (bash cannot create temp files there); a shell driver is missing")
    }

    func test_BUILD_14() async throws {
        then(when.readAppSource()).makesNoNetworkCalls()
    }
}
