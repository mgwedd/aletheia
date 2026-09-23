import Foundation

/// The composition axis for the app — which set of feature modules a build ships.
///
/// This replaces long-lived release branches with a single trunk plus build
/// composition. Tiers are **nested**: an `.mvp` module is in every build, a
/// `.preview` module is in preview and dev builds, a `.dev` module is only in
/// dev builds. A target is compiled at one tier and the composition root links
/// exactly the modules at or below it.
///
/// ```
///   mvp ─────────────▶ preview ─────────────▶ dev
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
    case mvp
    /// Complete but still maturing features, surfaced to testers.
    case preview
    /// Experimental or in-progress work, developer builds only.
    case dev

    /// Ascending breadth: `.mvp` is the smallest included set, `.dev` the largest.
    private var rank: Int {
        switch self {
        case .mvp: return 0
        case .preview: return 1
        case .dev: return 2
        }
    }

    static func < (lhs: BuildTier, rhs: BuildTier) -> Bool { lhs.rank < rhs.rank }

    /// Whether a build at this tier ships a module declared at `moduleTier`.
    /// A build includes everything at or below its own tier.
    func includes(_ moduleTier: BuildTier) -> Bool { moduleTier <= self }

    /// The tier this build was compiled as, read from the `AletheiaBuildTier`
    /// Info.plist value (set per target in `project.yml`). Defaults to `.mvp` so
    /// a plain build — and any build that forgets to set it — is the thin product,
    /// never accidentally the everything build. An unrecognized value also falls
    /// back to `.mvp`.
    static var current: BuildTier {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "AletheiaBuildTier") as? String,
              let tier = BuildTier(rawValue: raw) else {
            return .mvp
        }
        return tier
    }
}
