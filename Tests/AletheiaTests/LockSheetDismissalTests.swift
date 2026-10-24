import XCTest
@testable import Aletheia

final class LockSheetDismissalTests: XCTestCase {
    @MainActor
    func testLockBumpsGeneration() {
        let suite = "lock-sheet-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.appLockEnabled = true
        let appLock = AppLock(settings: settings, canAuthenticate: { true })
        appLock.simulateUnlockedForTesting()
        let before = appLock.lockGeneration

        appLock.lockIfEnabled()
        XCTAssertEqual(appLock.lockGeneration, before + 1)

        appLock.lockIfEnabled()
        XCTAssertEqual(appLock.lockGeneration, before + 1, "locking while already locked changes nothing")

        appLock.simulateUnlockedForTesting()
        XCTAssertEqual(appLock.lockGeneration, before + 1, "unlocking does not move the generation")
        appLock.lockIfEnabled()
        XCTAssertEqual(appLock.lockGeneration, before + 2)
    }

    @MainActor
    func testLockDoesNotBumpGenerationWhenTheLockIsOff() {
        let suite = "lock-sheet-off-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.appLockEnabled = false
        let appLock = AppLock(settings: settings, canAuthenticate: { true })
        appLock.lockIfEnabled()
        XCTAssertEqual(appLock.lockGeneration, 0)
    }

    func testSheetDismissesWhenGenerationChanges() {
        XCTAssertTrue(LockSheetPolicy.shouldDismiss(presentedGeneration: 0, currentGeneration: 1))
        XCTAssertTrue(LockSheetPolicy.shouldDismiss(presentedGeneration: 3, currentGeneration: 4))
        XCTAssertFalse(LockSheetPolicy.shouldDismiss(presentedGeneration: 2, currentGeneration: 2))
    }

    func testEverySheetOwnerClosesItsSheetsOnLock() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let owners: [(file: String, flag: String)] = [
            ("Views/RootView.swift", "showSettings = false"),
            ("Views/PatientsListView.swift", "showAddPatient = false"),
            ("Views/SessionDetailView.swift", "showScheduleSheet = false"),
            ("Views/SettingsView.swift", "showEncryptionSetup = false"),
            ("Views/MermaidDiagramView.swift", "isExpanded = false"),
            ("Views/DoctorView.swift", "showReviewRecords = false"),
            ("Views/DamagedRecordsNotice.swift", "reviewingEntry = nil"),
            ("Views/Settings/SetAsideRecordingsPane.swift", "recovering = nil"),
            ("Views/PatientProfileEditor.swift", "dismiss()"),
        ]
        for owner in owners {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/App/\(owner.file)"), encoding: .utf8)
            guard let range = source.range(of: ".dismissOnLock {") else { XCTFail("\(owner.file) never closes on lock"); continue }
            XCTAssertTrue(source[range.upperBound...].prefix(400).contains(owner.flag), "\(owner.file) must reset \(owner.flag)")
        }
        let app = try String(contentsOf: root.appendingPathComponent("Sources/App/AletheiaApp.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains(".environment(\\.lockGeneration, appLock.lockGeneration)"))
    }

    func testProfileEditorKeepsUnsavedEditsAcrossALock() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let editor = try String(contentsOf: root.appendingPathComponent("Sources/App/Views/PatientProfileEditor.swift"), encoding: .utf8)
        XCTAssertTrue(editor.contains("onLockDraft(draft.hasChanges ? draft.edited : nil)"))
        let rootView = try String(contentsOf: root.appendingPathComponent("Sources/App/Views/RootView.swift"), encoding: .utf8)
        XCTAssertTrue(rootView.contains("draft: lockedProfileDraft?.id == patient.id"))
    }

    func testNoSheetIsPresentedByTheUnlockItself() throws {
        // The dismiss handlers only ever set presentation flags to false; none of
        // them is wired to an unlock, so a closed sheet stays closed.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/App/Views/LockDismissal.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("isLocked"))
    }
}
