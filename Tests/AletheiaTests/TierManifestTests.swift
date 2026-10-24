import XCTest
@testable import Aletheia

/// A checked-in manifest of which build tier each feature module ships in.
/// Changing a module's tier (promoting it toward production) means editing the
/// map below on purpose; adding a module means deciding its tier here too.
final class TierManifestTests: XCTestCase {
    /// module id -> the tier the module is declared at. A build at tier T ships
    /// every module whose tier is at or below T.
    private static let manifest: [String: BuildTier] = [
        // Production: ships to clinicians.
        "embeddedLlama": .production,
        "doctor": .production,
        "sourceCitations": .production,
        // Preview: testers only.
        "spotlightIndexing": .preview,
        "suggestedQuestions": .preview,
        "patientMedications": .preview,
        // Dev: developer builds only.
        "atRestEncryption": .dev,
        "eventKitScheduling": .dev,
        "appIntents": .dev
    ]

    /// Ids present only in developer builds, because their code is compiled out
    /// elsewhere.
    private static let devCompiledOnly: Set<String> = ["appIntents"]

    func testManifestCoversEveryModule() {
        let ids = FeatureRegistry.allModules.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate module ids in the catalog")
        for id in ids {
            XCTAssertNotNil(Self.manifest[id], "module \(id) has no tier in the manifest; decide its tier")
        }
        // Every manifest line must still name a real module (no stale entries).
        let expected = Set(Self.manifest.keys).subtracting(BuildTier.compiled == .dev ? [] : Self.devCompiledOnly)
        XCTAssertEqual(Set(ids), expected)
    }

    func testEveryModuleTierMatchesManifest() {
        for module in FeatureRegistry.allModules {
            XCTAssertEqual(module.tier, Self.manifest[module.id], "\(module.id) is declared at a different tier than the manifest")
        }
    }

    func testEachBuildTierShipsExactlyTheManifestModules() {
        for tier in BuildTier.allCases {
            let shipped = Set(FeatureRegistry.compose(tier: tier, from: FeatureRegistry.allModules).ids)
            let expected = Set(Self.manifest.filter { tier.includes($0.value) }.keys)
                .subtracting(BuildTier.compiled == .dev ? [] : Self.devCompiledOnly)
            XCTAssertEqual(shipped, expected, "unexpected module set for \(tier)")
        }
    }
}
