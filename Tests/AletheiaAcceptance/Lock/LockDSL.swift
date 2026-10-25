@testable import Aletheia
import AppKit
import Combine
import Foundation
import LocalAuthentication
import XCTest

// MARK: - Subjects

struct RelockResult { let missed: [String] }

/// Answers the unlock sheet from a script instead of showing it.
final class ScriptedAuthenticator: UnlockAuthenticator {
    enum Answer { case succeeds, cancelled, fails }
    var next: Answer = .succeeds
    private(set) var prompts = 0

    func authenticate(reason: String) async throws -> Bool {
        prompts += 1
        switch next {
        case .succeeds: return true
        case .cancelled: throw LAError(.userCancel)
        case .fails: throw LAError(.authenticationFailed)
        }
    }
}

/// What the Mac tells the app about itself.
final class MacSwitches {
    var canAuthenticate = true
    var recordingOrTranscribing = false
}

/// A window the test can put on screen, standing in for one the app shows.
final class PopoverWindowStub: NSWindow {}

/// The app's lock, wired the way the app's launch wires it, over the driver's
/// settings and encryption.
@MainActor
final class LockedMac {
    let app: InProcessDriver
    let lock: AppLock
    let authenticator = ScriptedAuthenticator()
    let switches = MacSwitches()
    let shield: WindowShield
    let workChanged = PassthroughSubject<Void, Never>()
    let mainWindow: NSWindow
    let sheet: NSWindow
    let popover: NSWindow
    private(set) var keyDrops = 0

    fileprivate init(app: InProcessDriver) {
        self.app = app
        let switches = switches
        let authenticator = authenticator
        // Built-in app lock rule: with the folder key kept on this Mac the lock
        // cannot be off. Builds without that rule take the plain initializer.
        #if LOCK_REQUIRED_SEAM
        let encryption = app.encryption
        let lock = AppLock(
            settings: app.settings,
            canAuthenticate: { switches.canAuthenticate },
            authenticator: authenticator,
            isAppActive: { true },
            spotlight: SilentSpotlight(),
            now: { [clock = app.clock] in clock.now },
            lockRequired: { [weak encryption] in encryption?.requiresAppLock ?? false })
        #else
        let lock = AppLock(
            settings: app.settings,
            canAuthenticate: { switches.canAuthenticate },
            authenticator: authenticator,
            isAppActive: { true },
            spotlight: SilentSpotlight(),
            now: { [clock = app.clock] in clock.now })
        #endif
        self.lock = lock
        mainWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                         styleMask: [.titled], backing: .buffered, defer: true)
        popover = PopoverWindowStub(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                    styleMask: [.borderless], backing: .buffered, defer: true)
        let windows = [mainWindow, sheet, popover]
        shield = WindowShield(appLock: lock, settings: app.settings, windows: { windows })
        if lock.isLocked { app.encryption.lock() }
        lock.onLock = { [weak self] in
            self?.keyDrops += 1
            self?.app.encryption.lock()
        }
        lock.onUnlock = { [weak self] in self?.app.encryption.autoUnlockFromDevice() }
        lock.observeBackgroundWork(
            busy: { switches.recordingOrTranscribing },
            changes: workChanged.eraseToAnyPublisher())
        shield.start()
    }

    var isLocked: Bool { lock.isLocked }

    var topCover: LockCoverPolicy.Cover? {
        LockCoverPolicy.topCover(
            appLocked: lock.isLocked, hasDataFolder: true, encryption: app.encryption.state)
    }

    /// Waits until `condition` holds, polling the main loop, for at most `seconds`.
    @discardableResult
    func eventually(upTo seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    var nothingIsHidden: Bool { [mainWindow, sheet, popover].allSatisfy { !shield.isHidden($0) } }

    /// Waits up to `seconds` for the lock to engage.
    func waitUntilLocked(upTo seconds: TimeInterval) async -> Bool {
        await eventually(upTo: seconds) { lock.isLocked }
    }

    func putSheetAndPopoverOnScreen() {
        mainWindow.beginSheet(sheet)
    }

    func restoreGlobalState() {
        lock.simulateUnlockedForTesting()
    }
}

/// A clipboard of its own, so the check never touches the real one.
struct NamedClipboard {
    let pasteboard: NSPasteboard

    var pastedText: String? { pasteboard.string(forType: .string) }
    func holds(_ type: NSPasteboard.PasteboardType) -> Bool {
        pasteboard.pasteboardItems?.contains { $0.types.contains(type) } ?? false
    }
}

/// How long the app took to lock, in seconds.
struct IdleLockResult {
    let lockedBeforeAMinute: Bool
    let lockedAfterAMinute: Bool
}

/// The Auto-lock choices as Settings lists them.
struct AutoLockChoices {
    let names: [String]
    let newInstallDefaultMinutes: Int
}

/// A text view the app creates for patient text.
/// What turning App lock off did.
struct AppLockSwitch {
    let prompts: Int
    let stillOn: Bool
}

/// The "Lock when Aletheia is hidden" setting as an install has it.
struct InstallSettings {
    let locksWhenHidden: Bool
}

/// What deleting a recording told the user.
struct RecordingDeletion {
    let reportedNotDeleted: Bool
    let audioLeftBehind: Bool
}

struct PatientTextViewState {
    let writingToolsOff: Bool
}

/// A window's visibility to screen capture.
struct CaptureView {
    let sharingByWindow: [String: NSWindow.SharingType]
}

/// How patient names read in the menu bar panel and whether it can record.
struct MenuBarPanel {
    let label: String
    let canStartRecording: Bool
}

// MARK: - Given

extension Given {
    /// Launches Aletheia with App lock on over this data folder.
    func launchedWithAppLock() -> LockedMac {
        LockedMac(app: app)
    }

    /// Turns encryption on and lets this Mac remember the key, so unlocking the
    /// app opens the folder as it does for a user who kept that setting.
    func encryptedFolderRememberedOnThisMac() throws {
        try app.encryption.enable(passphrase: "correct horse battery staple", iterations: 1_000)
        try app.encryption.rememberOnDevice()
    }

    func appLockSavedAsOff() { app.settings.appLockEnabled = false }

    /// Encryption on, with the key not kept on this Mac.
    func encryptedFolderNotRememberedOnThisMac() throws {
        try app.encryption.enable(passphrase: "correct horse battery staple", iterations: 1_000)
    }

    func autoLockAfter(minutes: Int) { app.settings.idleAutoLockMinutes = minutes }
    func hideFromScreenSharing(_ on: Bool) { app.settings.hideFromScreenSharing = on }
    func allowScreenSharingThisSession() { app.settings.allowScreenSharingThisSession = true }
    func aRecordingIsRunning(_ mac: LockedMac) { mac.switches.recordingOrTranscribing = true }
}

// MARK: - When

extension When {
    func unlock(_ mac: LockedMac) async {
        mac.authenticator.next = .succeeds
        await mac.lock.unlock()
        await mac.eventually { !mac.lock.isLocked && mac.nothingIsHidden && mac.sheet.alphaValue == 1 }
    }

    /// Leaves the Mac in each way macOS announces it (screen lock, screensaver,
    /// sleep, fast user switch), unlocking in between.
    func leaveTheMacEachWay(_ mac: LockedMac) async -> RelockResult {
        var missed: [String] = []
        for trigger in RelockTrigger.allCases {
            await unlock(mac)
            if trigger.isDistributed {
                DistributedNotificationCenter.default().postNotificationName(
                    trigger.notificationName, object: nil, userInfo: nil, deliverImmediately: true)
            } else {
                NSWorkspace.shared.notificationCenter.post(name: trigger.notificationName, object: nil)
            }
            if !(await mac.waitUntilLocked(upTo: 3)) { missed.append(trigger.notificationName.rawValue) }
        }
        return RelockResult(missed: missed)
    }

    /// Leaves the app alone for a minute, one second at a time, as the idle timer sees it.
    func leaveAloneForAMinute(_ mac: LockedMac) async -> IdleLockResult {
        await mac.eventually { mac.lock.isWatchingForIdle }
        app.clock.advance(by: 59)
        mac.lock.checkIdleTimeout()
        let early = mac.lock.isLocked
        app.clock.advance(by: 1)
        mac.lock.checkIdleTimeout()
        await mac.eventually { mac.lock.isLocked }
        return IdleLockResult(lockedBeforeAMinute: early, lockedAfterAMinute: mac.lock.isLocked)
    }

    func lookAtAutoLockChoices() -> AutoLockChoices {
        let fresh = AppSettings(defaults: UserDefaults(suiteName: "aletheia-lock-fresh-\(UUID().uuidString)")!)
        return AutoLockChoices(
            names: IdleAutoLockTimeout.allCases.map(\.displayName),
            newInstallDefaultMinutes: fresh.idleAutoLockMinutes)
    }

    func lockWithSheetPopoverAndMenuBarPanelOpen(_ mac: LockedMac) async -> MenuBarPanel {
        mac.putSheetAndPopoverOnScreen()
        mac.lock.lockIfEnabled()
        await mac.eventually { mac.shield.isHidden(mac.sheet) && mac.shield.isHidden(mac.popover) }
        return MenuBarPanel(
            label: MenuBarContentPolicy.patientLabel(name: "Jane Doe", showFullName: true, isLocked: mac.lock.isLocked),
            canStartRecording: MenuBarContentPolicy.canStartRecording(isLocked: mac.lock.isLocked, isStarting: false))
    }

    func lockTheApp(_ mac: LockedMac) async {
        mac.lock.lockIfEnabled()
        await mac.eventually { mac.lock.isLocked && mac.mainWindow.sharingType == .none }
    }

    /// Turns App lock off in Settings; Touch ID answers as scripted.
    func turnAppLockOff(_ mac: LockedMac, touchIDSucceeds: Bool) async -> AppLockSwitch {
        mac.authenticator.next = touchIDSucceeds ? .succeeds : .cancelled
        let before = mac.authenticator.prompts
        let gate = SensitiveActionGate(authenticator: mac.authenticator, canAuthenticate: { true })
        _ = await gate.perform(.turnOffAppLock) { mac.app.settings.appLockEnabled = false }
        return AppLockSwitch(prompts: mac.authenticator.prompts - before, stillOn: mac.app.settings.appLockEnabled)
    }

    func openFreshInstall() -> InstallSettings {
        let fresh = AppSettings(defaults: UserDefaults(suiteName: "aletheia-lock-fresh-\(UUID().uuidString)")!)
        return InstallSettings(locksWhenHidden: fresh.lockWhenHidden)
    }

    func reopenInstallThatTurnedLockWhenHiddenOff() -> InstallSettings {
        let suite = "aletheia-lock-saved-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        AppSettings(defaults: defaults).lockWhenHidden = false
        return InstallSettings(locksWhenHidden: AppSettings(defaults: defaults).lockWhenHidden)
    }

    /// Deletes the session's recording while its temporary audio folder holds a
    /// file that cannot be removed.
    func deleteRecording(of patient: Patient, whoseTemporaryFolderCannotBeRemoved: Bool) async throws -> RecordingDeletion {
        let store = try XCTUnwrap(app.appModel.store)
        let session = try store.createSession(for: patient, on: app.clock.now)
        let staging = Store.stagingDir(for: session.id)
        let staged = staging.appendingPathComponent("mic.caf")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: staged)
        if whoseTemporaryFolderCannotBeRemoved {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: staging.path)
        }
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
            try? FileManager.default.removeItem(at: staging)
        }
        var reported = false
        do { try store.deleteRecordings(for: patient, session: session) } catch StoreError.recordingNotDeleted { reported = true }
        return RecordingDeletion(reportedNotDeleted: reported, audioLeftBehind: FileManager.default.fileExists(atPath: staged.path))
    }

    func finishTheRecording(_ mac: LockedMac) async {
        mac.switches.recordingOrTranscribing = false
        mac.workChanged.send()
        await mac.eventually { mac.keyDrops == 1 }
    }

    func lookAtCapture(of mac: LockedMac) async -> CaptureView {
        mac.shield.apply()
        return CaptureView(sharingByWindow: [
            "main window": mac.mainWindow.sharingType,
            "sheet": mac.sheet.sharingType,
            "popover": mac.popover.sharingType,
        ])
    }

    func copyPatientText(_ text: String) -> NamedClipboard {
        let board = NSPasteboard(name: .init("aletheia-lock-\(UUID().uuidString)"))
        PHIPasteboard.writeString(text, to: board)
        return NamedClipboard(pasteboard: board)
    }

    func selectTranscriptText() -> PatientTextViewState {
        let view = PatientTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        if #available(macOS 15, *) {
            return PatientTextViewState(writingToolsOff: view.writingToolsBehavior == .none)
        }
        return PatientTextViewState(writingToolsOff: true)
    }
}

// MARK: - Then

@MainActor
extension Then where Subject == LockedMac {
    func showsLockScreen() {
        expect(subject.isLocked, "expected the app to be locked")
        expectEqual(subject.topCover, .appLock, "the cover over the window")
    }

    func showsNoLockScreen() {
        expect(!subject.isLocked, "expected the app to be unlocked")
        expect(subject.topCover == nil, "expected no cover, found \(String(describing: subject.topCover))")
    }

    func isLocked() { expect(subject.isLocked, "expected the app to be locked") }

    func sheetAndPopoverAreHidden() {
        expect(subject.shield.isHidden(subject.sheet), "expected the sheet to be hidden")
        expect(subject.shield.isHidden(subject.popover), "expected the popover to be hidden")
        expect(subject.sheet.alphaValue == 0, "expected the sheet to be fully transparent")
        expect(subject.popover.alphaValue == 0, "expected the popover to be fully transparent")
    }

    func sheetAndPopoverAreShownAgain() {
        expect(!subject.shield.isHidden(subject.sheet), "expected the sheet to be back after unlocking")
        expect(subject.sheet.alphaValue == 1, "expected the sheet to be visible after unlocking")
        expect(subject.popover.alphaValue == 1, "expected the popover to be visible after unlocking")
    }

    func ignoresInputToHiddenWindows() {
        let action = WindowSharingPolicy.lockedEventAction(
            isLocked: subject.isLocked,
            windowIsHidden: subject.shield.isHidden(subject.popover),
            attachedSheetIsHidden: false, isMouseDown: true)
        expectEqual(action, .drop, "what happens to a click on a hidden window")
    }

    func keepsTheFolderKey() {
        expectEqual(subject.keyDrops, 0, "times the folder key was dropped")
        expect(subject.app.encryption.isUnlocked, "expected the encrypted folder to stay unlocked")
        expect(subject.lock.keyDropPending, "expected the key drop to wait for the recording")
    }

    func dropsTheFolderKey() {
        expectEqual(subject.keyDrops, 1, "times the folder key was dropped")
        expect(!subject.app.encryption.isUnlocked, "expected the encrypted folder to lock once the work ended")
    }

    func recordingStillRuns() {
        expect(subject.switches.recordingOrTranscribing, "expected the recording to still be running")
    }
}

extension Then where Subject == IdleLockResult {
    func lockedAboutAMinuteLater() {
        expect(!subject.lockedBeforeAMinute, "expected no lock before a minute of idle time")
        expect(subject.lockedAfterAMinute, "expected the app to lock after a minute of idle time, it never did")
    }
}

extension Then where Subject == AutoLockChoices {
    func offersNeverAndOneMinuteAmongTheChoices() {
        expect(subject.names.contains(Copy.autoLockNever), "expected a Never choice, found \(subject.names)")
        expect(subject.names.contains(Copy.autoLockOneMinute), "expected a 1 minute choice, found \(subject.names)")
    }

    func defaultsToFifteenMinutes() {
        expectEqual(subject.newInstallDefaultMinutes, 15, "Auto-lock after on a new install")
    }
}

extension Then where Subject == MenuBarPanel {
    func hidesPatientNameAndRecording() {
        expect(!subject.label.contains("Jane"), "expected the menu bar not to show the patient's name, found \(subject.label)")
        expect(!subject.canStartRecording, "expected recording not to start from the menu bar while locked")
    }
}

extension Then where Subject == CaptureView {
    func isBlankToOtherApps() {
        for (name, sharing) in subject.sharingByWindow.sorted(by: { $0.key < $1.key }) {
            expect(sharing == .none, "expected the \(name) to be hidden from capture, sharing type is \(sharing.rawValue)")
        }
    }

    func isVisibleToOtherApps() {
        for (name, sharing) in subject.sharingByWindow.sorted(by: { $0.key < $1.key }) {
            expect(sharing != .none, "expected the \(name) to be capturable, it is hidden")
        }
    }
}

extension Then where Subject == NamedClipboard {
    func pastesText(_ text: String) { expectEqual(subject.pastedText, text, "the pasted text") }

    func asksClipboardManagersNotToKeepIt() {
        expect(subject.holds(PHIPasteboard.concealed), "expected the concealed marker on the clipboard")
        expect(subject.holds(PHIPasteboard.transient), "expected the transient marker on the clipboard")
    }
}

extension Then where Subject == PatientTextViewState {
    func offersNoWritingTools() { expect(subject.writingToolsOff, "expected Writing Tools to be off on patient text") }
}

extension Then where Subject == RelockResult {
    func lockedAfterEveryWayOfLeaving() {
        expect(subject.missed.isEmpty, "the app stayed unlocked after: \(subject.missed.joined(separator: ", "))")
    }
}

@MainActor
extension Then where Subject == LockedMac {
    func showsNoPatients() {
        expect(subject.app.appModel.patients.isEmpty, "expected no patient to be readable while locked, found \(subject.app.appModel.patients.map(\.name))")
        expect(!subject.app.encryption.isUnlocked, "expected the folder key not to be loaded while locked")
    }

    func showsPatients(_ names: [String]) {
        expectEqual(subject.app.appModel.patients.map(\.name), names, "the patients shown after unlocking")
    }

    func openedWithoutAskingForAPassphrase() {
        expect(subject.app.encryption.isUnlocked, "expected the folder to open after Touch ID alone")
        expect(subject.topCover == nil, "expected no cover, found \(String(describing: subject.topCover))")
    }
}

extension Then where Subject == AppLockSwitch {
    func askedForTouchID() { expectEqual(subject.prompts, 1, "Touch ID prompts") }
    func leftAppLockOn() { expect(subject.stillOn, "expected App lock to stay on") }
    func turnedAppLockOff() { expect(!subject.stillOn, "expected App lock to be off") }
}

extension Then where Subject == InstallSettings {
    func locksWhenHidden() { expect(subject.locksWhenHidden, "expected Lock when Aletheia is hidden to be on") }
    func doesNotLockWhenHidden() { expect(!subject.locksWhenHidden, "expected Lock when Aletheia is hidden to stay off") }
}

extension Then where Subject == RecordingDeletion {
    func saysTheRecordingWasNotDeleted() {
        expect(subject.reportedNotDeleted, "expected a \"not deleted\" notice; the app reported success")
        expect(subject.audioLeftBehind, "expected the audio to still be on disk in this setup")
    }
}
