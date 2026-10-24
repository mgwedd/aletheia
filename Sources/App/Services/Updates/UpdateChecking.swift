import Foundation

/// One published release, as described by the update feed.
struct ReleaseInfo: Decodable, Equatable {
    let version: String
    let downloadURL: URL
    let releaseNotes: String
    let minimumSystemVersion: String?
    let publishedAt: Date?
    /// SHA-256 of the release archive, written into the feed after the archive
    /// is notarized. Older feeds don't have it.
    let sha256: String?

    enum CodingKeys: String, CodingKey {
        case version
        case downloadURL
        case releaseNotes
        case minimumSystemVersion
        case publishedAt
        case sha256
    }

    init(
        version: String,
        downloadURL: URL,
        releaseNotes: String,
        minimumSystemVersion: String? = nil,
        publishedAt: Date? = nil,
        sha256: String? = nil
    ) {
        self.version = version
        self.downloadURL = downloadURL
        self.releaseNotes = releaseNotes
        self.minimumSystemVersion = minimumSystemVersion
        self.publishedAt = publishedAt
        self.sha256 = sha256
    }
}

/// The one page the app opens for releases: Aletheia's download page on
/// astrealabs.com. Links in the update feed are never opened in the browser.
enum ReleaseLink {
    static let downloadsPage = URL(string: "https://astrealabs.com/aletheia/download")!
}

/// The update-source integration (another adapter seam). The default
/// implementation polls a small JSON feed; it could just as well read a
/// Sparkle-style appcast or a different endpoint without changing the
/// service or UI above it.
protocol UpdateChecking {
    func fetchLatest() async throws -> ReleaseInfo
}

/// Fetches and decodes the JSON release manifest through the network helper.
/// The feed is expected to describe the single latest release:
///
///     { "version": "1.1.0",
///       "downloadURL": "https://.../Aletheia-1.1.0.dmg",
///       "releaseNotes": "…",
///       "minimumSystemVersion": "14.0",
///       "publishedAt": "2026-09-16T00:00:00Z",
///       "sha256": "…" }
///
/// Which feed to read is the helper's business (its address is compiled into
/// the helper); the app can't name one.
struct AppcastUpdateChecker: UpdateChecking {
    var helper: NetworkHelping = NetworkHelperClient.shared

    func fetchLatest() async throws -> ReleaseInfo {
        let data = try await helper.fetchAppcast()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ReleaseInfo.self, from: data)
    }
}
