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
    let clock = FixtureClock()
    let probe: DataFolderProbe
    private(set) var tier: BuildTier
    private(set) var settings: AppSettings
    private(set) var encryption: EncryptionManager
    private(set) var appModel: AppModel

    private let defaultsSuite: String
    private let defaults: UserDefaults
    private let deviceKeys = ProcessMemoryDeviceKeyStore()

    init(tier: BuildTier = .dev) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aletheia-acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        probe = DataFolderProbe(root: root)
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
        settings.dataRootURL = root
        let encryption = EncryptionManager(
            dataRootProvider: { root }, deviceKeys: deviceKeys, defaults: defaults)
        let model = AppModel(
            settings: settings, encryption: encryption, spotlightIndexer: SilentSpotlight(),
            featureRegistry: .compose(tier: tier, from: FeatureRegistry.allModules))
        model.diskProbe = disk
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

    func shutDown() async {
        await appModel.stopSearchSync()
        SessionSearch.index = SearchIndex()
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }
}
