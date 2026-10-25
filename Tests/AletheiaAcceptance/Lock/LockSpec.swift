import XCTest

final class LockSpec: AcceptanceCase {
    private var launched: [LockedMac] = []

    private func launch() -> LockedMac {
        let mac = given.launchedWithAppLock()
        launched.append(mac)
        return mac
    }

    override func tearDown() async throws {
        launched.forEach { $0.restoreGlobalState() }
        launched = []
        try await super.tearDown()
    }

    func test_LOCK_01() async throws {
        try await given.patient(named: "Jane Doe")
        given.appRelaunched()

        let mac = launch()

        then(mac).showsLockScreen()

        try await when.unlock(mac)

        then(mac).showsNoLockScreen()
    }

    func test_LOCK_02() async throws {
        let mac = launch()

        then(try await when.leaveTheMacEachWay(mac)).lockedAfterEveryWayOfLeaving()
    }

    func test_LOCK_03() async throws {
        let choices = when.lookAtAutoLockChoices()
        then(choices).offersNeverAndOneMinuteAmongTheChoices()
        then(choices).defaultsToFifteenMinutes()

        let mac = launch()
        try await when.unlock(mac)
        given.autoLockAfter(minutes: 1)

        let result = try await when.leaveAloneForAMinute(mac)

        then(result).lockedAboutAMinuteLater()
    }

    func test_LOCK_04() async throws {
        let mac = launch()
        try await when.unlock(mac)

        let panel = try await when.lockWithSheetPopoverAndMenuBarPanelOpen(mac)

        then(mac).showsLockScreen()
        then(mac).sheetAndPopoverAreHidden()
        then(mac).ignoresInputToHiddenWindows()
        then(panel).hidesPatientNameAndRecording()

        try await when.unlock(mac)

        then(mac).sheetAndPopoverAreShownAgain()
    }

    func test_LOCK_05() async throws {
        let mac = launch()
        try await when.unlock(mac)

        // With the default setting, and again with it off, a locked app is blank.
        then(await when.lookAtCapture(of: mac)).isBlankToOtherApps()
        given.hideFromScreenSharing(false)
        then(await when.lookAtCapture(of: mac)).isVisibleToOtherApps()
        try await when.lockTheApp(mac)
        then(await when.lookAtCapture(of: mac)).isBlankToOtherApps()
    }

    func test_LOCK_06() async throws {
        try given.encryptedFolderRememberedOnThisMac()
        let mac = launch()
        try await when.unlock(mac)
        given.aRecordingIsRunning(mac)

        try await when.lockTheApp(mac)

        then(mac).isLocked()
        then(mac).recordingStillRuns()
        then(mac).keepsTheFolderKey()

        try await when.finishTheRecording(mac)

        then(mac).dropsTheFolderKey()
    }

    func test_LOCK_07() async throws {
        let clipboard = when.copyPatientText("Jane Doe, anxiety")

        then(clipboard).pastesText("Jane Doe, anxiety")
        then(clipboard).asksClipboardManagersNotToKeepIt()
    }

    func test_LOCK_08() async throws {
        then(when.selectTranscriptText()).offersNoWritingTools()
    }

    func test_LOCK_09() async throws {
        try given.encryptedFolderRememberedOnThisMac()
        given.appLockSavedAsOff()

        let mac = launch()

        then(mac).showsLockScreen()

        try await when.unlock(mac)
        try await when.lockTheApp(mac)

        then(mac).isLocked()
    }

    func test_LOCK_10() async throws {
        try pending("Settings > Security is a view; it needs a UI driver to read the App lock switch")
    }

    func test_LOCK_11() async throws {
        try given.encryptedFolderNotRememberedOnThisMac()
        let mac = launch()
        try await when.unlock(mac)

        let cancelled = await when.turnAppLockOff(mac, touchIDSucceeds: false)
        then(cancelled).askedForTouchID()
        then(cancelled).leftAppLockOn()

        let confirmed = await when.turnAppLockOff(mac, touchIDSucceeds: true)
        then(confirmed).askedForTouchID()
        then(confirmed).turnedAppLockOff()

        given.appRelaunched()
        then(launch()).showsNoLockScreen()
    }

    func test_LOCK_12() async throws {
        try await given.patient(named: "Jane Doe")
        try given.encryptedFolderRememberedOnThisMac()
        given.appRelaunched()

        let mac = launch()

        then(mac).showsLockScreen()
        then(mac).showsNoPatients()

        try await when.unlock(mac)

        then(mac).openedWithoutAskingForAPassphrase()
        then(mac).showsPatients(["Jane Doe"])
    }

    func test_LOCK_13() async throws {
        then(when.openFreshInstall()).locksWhenHidden()
        then(when.reopenInstallThatTurnedLockWhenHiddenOff()).doesNotLockWhenHidden()
    }

    func test_LOCK_14() async throws {
        let patient = try await given.patient(named: "Jane Doe")

        let deletion = try await when.deleteRecording(of: patient, whoseTemporaryFolderCannotBeRemoved: true)

        then(deletion).saysTheRecordingWasNotDeleted()
    }
}
