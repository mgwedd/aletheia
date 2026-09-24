import Foundation

/// Siri / Shortcuts / App Intents as a `FeatureModule`.
///
/// The intents work, but the setup-wizard permission flow they lean on has been
/// unreliable (see the reported permission-grant freeze), and a voice/automation
/// surface over PHI is exactly the kind of thing to withhold from the clinician
/// until it's proven. So this ships developer-build-only (`.dev`) and is absent
/// from the production and preview builds.
///
/// Gating is at the one place the surface is exposed: `AletheiaShortcuts`
/// (the `AppShortcutsProvider`) offers no shortcut phrases unless this module is
/// present in the running build's registry. The intent types themselves stay
/// compiled in — they do nothing until surfaced — so a build without this module
/// simply has no Siri/Shortcuts entry points, a clean gap rather than a broken
/// one.
struct AppIntentsFeatureModule: FeatureModule {
    /// Also usable as `AppIntentsFeatureModule.id` at call sites that only need
    /// the identifier to query the registry, without constructing an instance.
    static let id = "appIntents"

    var id: String { Self.id }
    let title = "Siri & Shortcuts"
    let tier: BuildTier = .dev
}
