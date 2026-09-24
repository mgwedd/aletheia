// The App Intents module descriptor exists only in builds that actually compile
// the App Intents surface (`.dev` tier). In production/preview the surface is
// `#if ALETHEIA_DEV`-excluded, so there's nothing to describe and this type is
// absent too — the registry simply never lists it.
#if ALETHEIA_DEV
import Foundation

/// Siri / Shortcuts (App Intents) as a `FeatureModule`.
///
/// Unlike the other modules, App Intents can't be gated at runtime: the shortcut
/// metadata is extracted at build time and `AppShortcutsBuilder` rejects
/// conditionals. So the whole surface (see `AletheiaIntents.swift`,
/// `PatientEntity.swift`) is excluded from the binary with `#if ALETHEIA_DEV`,
/// and this descriptor is registered only in that same tier. It's `.dev` because
/// the intents lean on the setup-wizard permission flow that's still unreliable.
struct AppIntentsFeatureModule: FeatureModule {
    /// Also usable as `AppIntentsFeatureModule.id` at call sites that only need
    /// the identifier to query the registry, without constructing an instance.
    static let id = "appIntents"

    var id: String { Self.id }
    let title = "Siri & Shortcuts"
    let tier: BuildTier = .dev
}
#endif
