import Foundation

/// The composition axis for the app — which set of feature modules a build ships.
///
/// This replaces long-lived release branches with a single trunk plus build
/// composition. Tiers are **nested**: a `.production` module is in every build, a
/// `.preview` module is in preview and dev builds, a `.dev` module is only in
/// dev builds. A target is compiled at one tier and the composition root links
/// exactly the modules at or below it.
///
/// ```
///   production ─────────────▶ preview ─────────────▶ dev
///   the thin product   + maturing features    + experimental / in-progress
///   the clinician runs  for testers            work
///
///   a build at tier T includes every module whose own tier ≤ T
/// ```
///
/// Keeping this an ordered value (not three diverging branches) is what lets a
/// solo maintainer roll a feature out by raising one module's tier, with no
/// merge reconciliation and no divergent security/doc state to keep in sync.
enum BuildTier: String, CaseIterable, Comparable, Codable {
    /// The lean, always-shippable core: record → transcribe → summarize → notes
    /// → chat, plus FileVault guidance and the app-open lock. What ships to the
    /// clinician.
    case production
    /// Complete but still maturing features, surfaced to testers.
    case preview
    /// Experimental or in-progress work, developer builds only.
    case dev

    /// Ascending breadth: `.production` is the smallest included set, `.dev` the largest.
    private var rank: Int {
        switch self {
        case .production: return 0
        case .preview: return 1
        case .dev: return 2
        }
    }

    static func < (lhs: BuildTier, rhs: BuildTier) -> Bool { lhs.rank < rhs.rank }

    /// Whether a build at this tier ships a module declared at `moduleTier`.
    /// A build includes everything at or below its own tier.
    func includes(_ moduleTier: BuildTier) -> Bool { moduleTier <= self }

    /// The tier this binary was **compiled** at, from the build configuration's
    /// Swift active compilation conditions (`project.yml`): Debug defines
    /// `ALETHEIA_DEV` (+`ALETHEIA_PREVIEW`), Release defines neither. This is the
    /// source of truth for the thin production build — preview/dev-only code
    /// guarded by these flags (e.g. App Intents) is absent from a `.production`
    /// binary, not merely hidden at runtime.
    static var compiled: BuildTier {
        #if ALETHEIA_DEV
        return .dev
        #elseif ALETHEIA_PREVIEW
        return .preview
        #else
        return .production
        #endif
    }

    /// The effective tier for this build. Defaults to the compiled tier; an
    /// `AletheiaBuildTier` Info.plist value, if present and valid, overrides it
    /// (an escape hatch for forcing a tier without a recompile — e.g. a QA
    /// build). A missing or unrecognized value falls back to `compiled`, so a
    /// plain Release build is always the thin `.production` product.
    static var current: BuildTier {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "AletheiaBuildTier") as? String,
           let tier = BuildTier(rawValue: raw) {
            return tier
        }
        return compiled
    }
}
