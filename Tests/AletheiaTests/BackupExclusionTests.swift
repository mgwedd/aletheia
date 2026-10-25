import XCTest
@testable import Aletheia

/// `BackupExclusion` round-trips the `isExcludedFromBackup` flag on a folder, so
/// the data folder can be kept out of (or allowed back into) Time Machine and
/// iCloud's device backup.
final class BackupExclusionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testDefaultIsNotExcluded() {
        XCTAssertFalse(BackupExclusion.isExcluded(at: dir))
    }

    // MARK: - Default policy (Time Machine includes the data folder)

    /// A throwaway `UserDefaults` suite, so tests never touch the real app
    /// preferences.
    private func makeDefaults() -> UserDefaults {
        let name = "BackupExclusionTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        addTeardownBlock { suite.removePersistentDomain(forName: name) }
        return suite
    }

    func testDefaultPolicyIsExcluded() {
        XCTAssertTrue(BackupExclusion.defaultExcluded)
    }

    func testUnsetKeyResolvesToDefaultExcluded() {
        let defaults = makeDefaults()
        XCTAssertFalse(BackupExclusion.hasExplicitChoice(in: defaults))
        XCTAssertTrue(BackupExclusion.resolvedExclusion(in: defaults))
    }

    func testExplicitTrueIsRespected() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: BackupExclusion.defaultsKey)
        XCTAssertTrue(BackupExclusion.hasExplicitChoice(in: defaults))
        XCTAssertTrue(BackupExclusion.resolvedExclusion(in: defaults))
    }

    func testExplicitFalseIsRespectedAndDistinctFromUnset() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: BackupExclusion.defaultsKey)
        XCTAssertTrue(BackupExclusion.hasExplicitChoice(in: defaults))
        XCTAssertFalse(BackupExclusion.resolvedExclusion(in: defaults))
    }

    func testRemovingStoredChoiceReturnsToDefault() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: BackupExclusion.defaultsKey)
        defaults.removeObject(forKey: BackupExclusion.defaultsKey)
        XCTAssertFalse(BackupExclusion.hasExplicitChoice(in: defaults))
        XCTAssertTrue(BackupExclusion.resolvedExclusion(in: defaults))
    }

    func testDefaultsKeyIsStable() {
        // Stored user choices are keyed by this string; renaming it would
        // silently discard every existing choice.
        XCTAssertEqual(BackupExclusion.defaultsKey, "keepDataOutOfSystemBackups")
    }

    func testExcludeThenIncludeRoundTrips() throws {
        try BackupExclusion.setExcluded(true, at: dir)
        XCTAssertTrue(BackupExclusion.isExcluded(at: dir), "excluded flag should read back true right after being set")

        try BackupExclusion.setExcluded(false, at: dir)
        XCTAssertFalse(BackupExclusion.isExcluded(at: dir), "excluded flag should read back false right after being cleared")
    }

    func testQuickTogglesEndOnTheLastChoice() throws {
        for _ in 0..<20 {
            try BackupExclusion.setExcluded(false, at: dir)
            try BackupExclusion.setExcluded(true, at: dir)
        }
        XCTAssertTrue(BackupExclusion.isExcluded(at: dir))
        try BackupExclusion.setExcluded(false, at: dir)
        XCTAssertFalse(BackupExclusion.isExcluded(at: dir))
    }

    func testClearingAFolderThatWasNeverExcludedSucceeds() {
        XCTAssertNoThrow(try BackupExclusion.setExcluded(false, at: dir))
        XCTAssertFalse(BackupExclusion.isExcluded(at: dir))
    }

    func testTheSettingAppliesToTheFolderAtOnce() {
        let name = "BackupExclusionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.dataRootURL = dir
        settings.keepDataOutOfSystemBackups = false
        XCTAssertFalse(BackupExclusion.isExcluded(at: dir))
        settings.keepDataOutOfSystemBackups = true
        XCTAssertTrue(BackupExclusion.isExcluded(at: dir))
    }
}

/// The Settings switches that default on, and the data folder that persists.
@MainActor
final class AppSettingsDefaultsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "AppSettingsDefaultsTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        addTeardownBlock { suite.removePersistentDomain(forName: name) }
        return suite
    }

    func testFreshInstallKeepsDataOutOfBackupsAndLocksWhenHidden() {
        let settings = AppSettings(defaults: makeDefaults())
        XCTAssertTrue(settings.keepDataOutOfSystemBackups)
        XCTAssertTrue(settings.lockWhenHidden)
    }

    func testExplicitOffChoicesStayOff() {
        let defaults = makeDefaults()
        let first = AppSettings(defaults: defaults)
        first.keepDataOutOfSystemBackups = false
        first.lockWhenHidden = false
        let second = AppSettings(defaults: defaults)
        XCTAssertFalse(second.keepDataOutOfSystemBackups)
        XCTAssertFalse(second.lockWhenHidden)
    }

    func testChosenDataFolderIsInUseAfterRelaunch() throws {
        let defaults = makeDefaults()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chosen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try AppSettings(defaults: defaults).setDataRoot(folder)
        let relaunched = AppSettings(defaults: defaults)
        XCTAssertEqual(relaunched.dataRootURL?.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
    }
}
