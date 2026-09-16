import Foundation

/// A minimal semantic version (major.minor.patch) for comparing the running
/// app against the latest published release. Pre-release/build metadata is
/// ignored — the update feed only ever advertises released versions.
struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses "1", "1.2", or "1.2.3" (missing components default to 0).
    /// Returns nil if the leading components aren't integers.
    init?(_ string: String) {
        let core = string.split(separator: "+").first.map(String.init) ?? string
        let base = core.split(separator: "-").first.map(String.init) ?? core
        let parts = base.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }

        func component(_ index: Int) -> Int? {
            guard index < parts.count else { return 0 }
            return Int(parts[index])
        }
        guard let major = component(0), let minor = component(1), let patch = component(2) else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
