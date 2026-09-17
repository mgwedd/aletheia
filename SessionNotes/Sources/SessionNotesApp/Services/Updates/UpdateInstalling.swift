import AppKit

/// How an available update is actually applied. Kept behind a protocol so the
/// install strategy can evolve without touching the check/prompt logic.
///
/// The default `GuidedDownloadInstaller` opens the release download so the
/// user can install the fresh copy themselves. This is deliberate: under App
/// Sandbox a running app cannot replace its own bundle in /Applications, so
/// a fully-automatic in-place update would need Sparkle's privileged XPC
/// installer (a dependency + code-signing keys). When that's wanted, it drops
/// in here as another `UpdateInstalling` implementation — the rest of the
/// update flow stays the same.
protocol UpdateInstalling {
    @MainActor func install(_ release: ReleaseInfo)
}

struct GuidedDownloadInstaller: UpdateInstalling {
    @MainActor
    func install(_ release: ReleaseInfo) {
        NSWorkspace.shared.open(release.downloadURL)
    }
}
