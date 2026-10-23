import Foundation
import Security

/// What the running app's own code signature says about network access. Read at
/// runtime from the signed entitlements (never hard-coded), so Settings shows
/// what macOS actually enforces for this copy of the app.
struct NetworkAccessFacts: Equatable {
    /// The app's entitlements, or nil when the running process's signature
    /// could not be read at all.
    var app: Entitlements?
    /// The bundled helper's entitlements, or nil when the helper is missing
    /// from the app bundle or its signature could not be read.
    var helper: Entitlements?

    struct Entitlements: Equatable {
        var sandboxed: Bool
        var networkClient: Bool
    }
}

/// How Settings describes the facts. Pure: no system calls, so every state is
/// testable.
struct NetworkAccessStatus: Equatable {
    enum State: Equatable {
        /// Sandboxed with no network entitlement: the app cannot connect.
        case noNetwork
        /// The app itself holds the network entitlement.
        case hasNetwork
        /// Not sandboxed (a local development or test run), so entitlements
        /// are not what limits this process.
        case notSandboxed
        /// The signature could not be read.
        case unreadable
    }

    enum Tone: Equatable { case ok, warn, neutral }

    let state: State
    let headline: String
    let detail: String
    let chipText: String
    let tone: Tone
    let helperSummary: String

    init(_ facts: NetworkAccessFacts) {
        switch facts.app {
        case nil:
            state = .unreadable
            headline = "Couldn't check network access"
            detail = "macOS didn't let Aletheia read its own signature. Use the command below to check it yourself."
            chipText = "Unknown"
            tone = .neutral
        case let app? where app.networkClient:
            state = .hasNetwork
            headline = "Aletheia can connect to the internet"
            detail = "This copy of the app holds the network entitlement. Official builds don't. Download Aletheia again from the official release page."
            chipText = "Review"
            tone = .warn
        case let app? where !app.sandboxed:
            state = .notSandboxed
            headline = "Not sandboxed (development build)"
            detail = "This copy isn't running in the App Sandbox, so macOS isn't restricting it. Official builds are sandboxed with no network access."
            chipText = "Not sandboxed"
            tone = .neutral
        default:
            state = .noNetwork
            headline = "Aletheia can't connect to the internet"
            detail = "The app is sandboxed and has no network entitlement, so macOS blocks every connection it tries to make. Only the helper below can go online."
            chipText = "No network"
            tone = .ok
        }

        switch facts.helper {
        case nil:
            helperSummary = "The network helper wasn't found or its signature couldn't be read."
        case let helper? where helper.sandboxed && helper.networkClient:
            helperSummary = "Sandboxed, with network access and nothing else: no files, no microphone, no patient data."
        case let helper?:
            helperSummary = helper.networkClient
                ? "Has network access but isn't sandboxed."
                : "Has no network access, so updates and model downloads can't run."
        }
    }
}

/// What the helper may fetch, for display. The helper's own table is the
/// authority; `NetworkHelperCatalogTests` keeps this list identical to it.
enum NetworkHelperDisclosure {
    static let hosts = ["github.com", "githubusercontent.com", "huggingface.co", "hf.co", "astrealabs.com", "aletheia.astrealabs.com"]

    /// One line per kind of download.
    static var downloads: [String] {
        var lines = ["Update check and update download (github.com, this app's releases only)"]
        lines.append("Daily signed license revocation list (astrealabs.com, only while update checks are on)")
        lines += WhisperModel.allCases.map { "Whisper \($0.shortName) transcription model" }
        lines += LlamaModel.allCases.map { "\($0.shortName) language model" }
        return lines
    }

    /// Where the helper lives inside the app bundle.
    static func helperURL(in bundle: Bundle = .main) -> URL {
        bundle.bundleURL.appendingPathComponent("Contents/XPCServices/NetworkHelper.xpc", isDirectory: true)
    }

    /// The command that prints the same entitlements from outside the app.
    static func verifyCommand(for bundle: Bundle = .main) -> String {
        "codesign -d --entitlements - \"\(bundle.bundleURL.path)\""
    }
}

/// Reads entitlements from live code signatures.
enum EntitlementReader {
    private static let sandboxKey = "com.apple.security.app-sandbox"
    private static let networkKey = "com.apple.security.network.client"

    static func current(bundle: Bundle = .main) -> NetworkAccessFacts {
        NetworkAccessFacts(
            app: ownEntitlements(),
            helper: entitlements(ofCodeAt: NetworkHelperDisclosure.helperURL(in: bundle)))
    }

    /// The running process's own entitlements (what the kernel enforces).
    static func ownEntitlements() -> NetworkAccessFacts.Entitlements? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        func flag(_ key: String) -> Bool {
            (SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? Bool) ?? false
        }
        return .init(sandboxed: flag(sandboxKey), networkClient: flag(networkKey))
    }

    /// The entitlements embedded in the signature of the code at `url`, or nil
    /// when it is missing or unsigned.
    static func entitlements(ofCodeAt url: URL) -> NetworkAccessFacts.Entitlements? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return nil }
        return .init(
            sandboxed: (entitlements[sandboxKey] as? Bool) ?? false,
            networkClient: (entitlements[networkKey] as? Bool) ?? false)
    }
}
