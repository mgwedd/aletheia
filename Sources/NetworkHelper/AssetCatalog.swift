import Foundation

/// Every download the helper will perform, and every host it will talk to.
/// This table is compiled into the helper; the app only ever sends an integer.
///
/// The raw values must equal the app's `AssetID` (`NetworkHelperCatalogTests`
/// asserts it, and that each URL equals the app's pinned model URL).
enum HelperAsset: Int, CaseIterable {
    case whisperBaseEn = 1
    case whisperSmallEn = 2
    case whisperMediumEn = 3
    case whisperLargeV3 = 4
    case llama31_8b = 10
    case gemma4_e2b = 11
    /// The release archive. Its URL is not in this table: the helper reads it
    /// from the appcast it fetches itself.
    case updateArchive = 20

    /// The fixed URL for a pinned model, or nil for the update archive.
    var fixedURL: URL? {
        switch self {
        case .whisperBaseEn: return Self.whisper("base.en")
        case .whisperSmallEn: return Self.whisper("small.en")
        case .whisperMediumEn: return Self.whisper("medium.en")
        case .whisperLargeV3: return Self.whisper("large-v3")
        case .llama31_8b:
            return Self.llama(
                repo: "Meta-Llama-3.1-8B-Instruct-Q4_0-GGUF",
                revision: "0aba27dd2f1c7f4941a94a5c59d80e0a256f9ff8",
                file: "meta-llama-3.1-8b-instruct-q4_0.gguf")
        case .gemma4_e2b:
            return Self.llama(
                repo: "gemma-4-E2B-it-GGUF",
                revision: "b4243c156154b6dca9324415f8c7ccc098b4aed1",
                file: "gemma-4-E2B-it-Q4_0.gguf")
        case .updateArchive: return nil
        }
    }

    private static let whisperRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"

    private static func whisper(_ name: String) -> URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(whisperRevision)/ggml-\(name).bin")!
    }

    private static func llama(repo: String, revision: String, file: String) -> URL {
        URL(string: "https://huggingface.co/ggml-org/\(repo)/resolve/\(revision)/\(file)")!
    }
}

enum HelperEndpoints {
    /// The update feed: the `appcast.json` of the latest GitHub release.
    static let appcast = URL(string: "https://github.com/mgwedd/aletheia/releases/latest/download/appcast.json")!

    /// The signed license revocation list. The same bytes for everyone: no
    /// query, cookie or credential, so the request says nothing about who asks.
    static let revocations = URL(string: "https://astrealabs.com/api/licenses/revocations")!

    /// The appcast's `downloadURL` is only followed when it is a release asset
    /// of this repository.
    static func isUpdateArchive(_ url: URL) -> Bool {
        HelperAllowlist.allows(url)
            && url.host?.lowercased() == "github.com"
            && url.path.hasPrefix("/mgwedd/aletheia/releases/download/")
            // No "." / ".." segments (decoded, so %2e%2e counts) that would
            // climb out of this repository's release assets.
            && !url.pathComponents.contains { $0 == "." || $0 == ".." }
    }
}

/// The only hosts the helper contacts, including the CDNs that GitHub and
/// Hugging Face redirect to, and the license revocation list's host. https only.
enum HelperAllowlist {
    /// A host matches when it equals an entry or is a subdomain of one, except
    /// the entries in `exactOnly`, which match only themselves.
    static let hosts = [
        "github.com",
        "githubusercontent.com",
        "huggingface.co",
        "hf.co",
        // TODO: drop the apex once the revocation list is served from aletheia.astrealabs.com.
        "astrealabs.com",
        "aletheia.astrealabs.com",
    ]

    /// Hosts we run ourselves match only exactly: no other subdomain is trusted,
    /// so one someone else takes over (a stale DNS record, say) can't serve the helper.
    static let exactOnly: Set<String> = ["astrealabs.com", "aletheia.astrealabs.com"]

    static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), !host.isEmpty
        else { return false }
        return hosts.contains { host == $0 || (!exactOnly.contains($0) && host.hasSuffix("." + $0)) }
    }
}
