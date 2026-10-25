@testable import Aletheia
import Foundation

/// Sets the scene. Core verbs live here; each journey adds its own in
/// `<Journey>/<Journey>DSL.swift` with `extension Given { ... }`.
@MainActor
struct Given {
    let app: InProcessDriver

    func fileVaultIsOn() { app.disk.state = .on }
    func fileVaultIsOff() { app.disk.state = .off }
    func fileVaultCannotBeRead() { app.disk.state = .unknown }

    /// The app as this build.
    func buildIs(_ build: AppBuild) { app.relaunch(tier: build.tier) }

    func appRelaunched() { app.relaunch(tier: app.tier) }
}

/// Which build of the app a check runs against.
enum AppBuild {
    /// The shipped Release build.
    case release
    /// A Debug or developer build.
    case dev

    var tier: BuildTier { self == .release ? .production : .dev }
}
