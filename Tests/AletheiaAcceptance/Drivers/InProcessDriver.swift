@testable import Aletheia
import Foundation
import XCTest

/// The real app object graph (settings, encryption, stores, model) over a
/// throwaway data folder, with the hardware swapped for fixtures: an in-memory
/// device keychain, a FileVault stub, a silent Spotlight and a clock the test
/// moves. It drives the same model actions the views call.
@MainActor
final class InProcessDriver {
    let root: URL
    let disk = FixtureDisk()
    let clock = TestClock()
    let probe: DataFolderProbe
    private(set) var tier: BuildTier
    private(set) var settings: AppSettings
    private(set) var encryption: EncryptionManager
    private(set) var appModel: AppModel

    private let defaultsSuite: String
    private let defaults: UserDefaults
    private let deviceKeys = ProcessMemoryDeviceKeyStore()
    /// Work started by the test's scene (schedulers, queues, held answers),
    /// stopped in order before the data folder is closed.
    private var stoppers: [() async -> Void] = []
    private let originalScratch = PrivateStaging.root

    init(tier: BuildTier = .dev) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aletheia-acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        probe = DataFolderProbe(root: root)
        // Process-wide state starts fresh for every test.
        PrivateStaging.root = root.appendingPathComponent("Scratch", isDirectory: true)
        SessionSearch.index = SearchIndex()
        defaultsSuite = "aletheia-acceptance-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)!
        self.tier = tier
        let built = Self.build(root: root, tier: tier, defaults: defaults, deviceKeys: deviceKeys, disk: disk)
        settings = built.settings
        encryption = built.encryption
        appModel = built.model
    }

    private static func build(
        root: URL, tier: BuildTier, defaults: UserDefaults, deviceKeys: DeviceKeyStoring, disk: FixtureDisk
    ) -> (settings: AppSettings, encryption: EncryptionManager, model: AppModel) {
        let settings = AppSettings(defaults: defaults)
        // A relaunch keeps the folder the app resolved from its saved choice.
        if settings.dataRootURL == nil { settings.dataRootURL = root }
        let encryption = EncryptionManager(
            dataRootProvider: { root }, deviceKeys: deviceKeys, defaults: defaults)
        let model = AppModel(
            settings: settings, encryption: encryption, spotlightIndexer: SilentSpotlight(),
            featureRegistry: .compose(tier: tier, from: FeatureRegistry.allModules))
        model.diskProbe = disk
        // The model read the disk when it opened the folder; read it again through the stub.
        model.refreshDiskEncryption()
        return (settings, encryption, model)
    }

    /// Quits and reopens the app over the same data folder, as a build of `tier`.
    func relaunch(tier: BuildTier) {
        self.tier = tier
        let built = Self.build(root: root, tier: tier, defaults: defaults, deviceKeys: deviceKeys, disk: disk)
        settings = built.settings
        encryption = built.encryption
        appModel = built.model
    }

    /// Runs `stop` at shutdown, before the data folder closes, in the order registered.
    func stopOnShutDown(_ stop: @escaping () async -> Void) {
        stoppers.append(stop)
    }

    /// Stops every piece of work the test started and waits for it, closes the
    /// data folder's databases, then deletes the folder and resets process-wide state.
    func shutDown() async {
        for stop in stoppers { await stop() }
        stoppers = []
        await appModel.stopSearchSync()
        settings.dataRootURL = nil
        appModel.rebuildStore()
        SessionSearch.index = SearchIndex()
        #if canImport(llama)
        LlamaAssistant.unloadAll()
        #endif
        UnsavedTranscriptDrafts.forgetAll()
        PrivateStaging.root = originalScratch
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }
}
