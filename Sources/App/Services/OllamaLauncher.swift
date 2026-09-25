import AppKit
import Foundation

/// Finds the user-installed Ollama.app. Aletheia never bundles or downloads
/// Ollama — this only locates an app the therapist already installed, the same
/// as `open -a Ollama` would, so the setup checklist can tell "not installed"
/// (send to the download page) apart from "installed but not running" (just
/// launch it).
///
/// The lookups are injected so this is unit-testable without `NSWorkspace` or
/// a real filesystem.
enum OllamaAppLocator {
    /// Bundle identifiers Ollama's Mac app has shipped under. Checked first;
    /// `fallbackApplicationPath` covers an install `NSWorkspace` doesn't know
    /// about by bundle id (e.g. copied in manually, or a future rename).
    static let knownBundleIdentifiers = ["com.electron.ollama", "com.ollama.ollama"]
    static let fallbackApplicationPath = "/Applications/Ollama.app"

    static func locate(
        urlForBundleIdentifier: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        for identifier in knownBundleIdentifiers {
            if let url = urlForBundleIdentifier(identifier) {
                return url
            }
        }
        return fileExists(fallbackApplicationPath) ? URL(fileURLWithPath: fallbackApplicationPath) : nil
    }

    static func isInstalled(
        urlForBundleIdentifier: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        locate(urlForBundleIdentifier: urlForBundleIdentifier, fileExists: fileExists) != nil
    }
}

/// Launches an already-installed Ollama.app in the background and waits for its
/// local HTTP server to answer. This is what closes the #111 gap: today the
/// app only ever opens the ollama.com download page and talks HTTP to
/// 127.0.0.1 — nothing ever starts the server, so if Ollama isn't already
/// running (e.g. after a reboot, or the user quit it) AI features stay dead
/// with no recovery short of the therapist remembering to open Ollama herself.
///
/// Launching a local, user-installed app via `NSWorkspace` needs no extra
/// entitlement under App Sandbox (it's mediated by Launch Services, not a
/// direct `Process`/`posix_spawn`), so this doesn't touch `Aletheia.entitlements`.
enum OllamaLauncher {
    enum LaunchError: LocalizedError, Equatable {
        case notInstalled
        case launchFailed
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Ollama isn't installed. Click “Get Ollama” to download it from ollama.com."
            case .launchFailed:
                return "Couldn't launch Ollama. Try opening it yourself from Applications."
            case .timedOut:
                return "Launched Ollama, but it didn't respond in time. Give it a moment and try again."
            }
        }
    }

    /// Opens the installed Ollama.app hidden/non-activating (so the therapist's
    /// current window keeps focus) and polls `isReachable` until it answers or
    /// `timeout` elapses.
    @MainActor
    static func launchAndWaitUntilReachable(
        timeout: TimeInterval = 15,
        pollInterval: TimeInterval = 0.5,
        isReachable: () async -> Bool
    ) async throws {
        guard let appURL = OllamaAppLocator.locate() else { throw LaunchError.notInstalled }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } catch {
            throw LaunchError.launchFailed
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await isReachable() { return }
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw LaunchError.timedOut
    }
}
