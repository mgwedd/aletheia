import AppKit

/// How an available update is actually applied. Kept behind a protocol so the
/// install strategy can evolve without touching the check/prompt logic.
///
/// The default `GuidedDownloadInstaller` fetches the release's disk image
/// through the network helper (the app has no network access of its own),
/// checks it against the digest published in the update feed, and opens it so
/// the user can drag the fresh copy into Applications. This is deliberate:
/// under App Sandbox a running app cannot replace its own bundle in
/// /Applications, so a fully-automatic in-place update would need Sparkle's
/// privileged XPC installer (a dependency + code-signing keys). When that's
/// wanted, it drops in here as another `UpdateInstalling` implementation — the
/// rest of the update flow stays the same.
protocol UpdateInstalling {
    @MainActor func install(_ release: ReleaseInfo)
}

struct GuidedDownloadInstaller: UpdateInstalling {
    var helper: NetworkHelping = NetworkHelperClient.shared
    /// Opens a file or web page (the default hands it to the system).
    var open: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Where the disk image is saved: inside the app's own container.
    var downloadsDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Updates", isDirectory: true)

    @MainActor
    func install(_ release: ReleaseInfo) {
        // A feed without a digest can't be checked, so it isn't downloaded
        // here: the downloads page opens in the browser instead.
        guard let sha256 = release.sha256 else {
            open(ReleaseLink.downloadsPage)
            return
        }
        let helper = helper, open = open
        let archive = downloadsDirectory.appendingPathComponent("Aletheia-update.dmg")
        Task { @MainActor in
            do {
                try await helper.download(.updateArchive, expectedSHA256: sha256, to: archive) { _ in }
                open(archive)
            } catch {
                open(ReleaseLink.downloadsPage)
            }
        }
    }
}
