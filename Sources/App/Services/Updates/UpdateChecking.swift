import Foundation

/// One published release, as described by the update feed.
struct ReleaseInfo: Decodable, Equatable {
    let version: String
    let downloadURL: URL
    let releaseNotes: String
    let minimumSystemVersion: String?
    let publishedAt: Date?
    let releasePageURL: URL?
    /// SHA-256 of the release archive, written into the feed after the archive
    /// is notarized. Older feeds don't have it.
    let sha256: String?

    enum CodingKeys: String, CodingKey {
        case version
        case downloadURL
        case releaseNotes
        case minimumSystemVersion
        case publishedAt
        case releasePageURL
        case sha256
    }

    init(
        version: String,
        downloadURL: URL,
        releaseNotes: String,
        minimumSystemVersion: String? = nil,
        publishedAt: Date? = nil,
        releasePageURL: URL? = nil,
        sha256: String? = nil
    ) {
        self.version = version
        self.downloadURL = downloadURL
        self.releaseNotes = releaseNotes
        self.minimumSystemVersion = minimumSystemVersion
        self.publishedAt = publishedAt
        self.releasePageURL = releasePageURL
        self.sha256 = sha256
    }

    /// URL to view this release in a browser, or nil when the feed supplied
    /// nothing that points at this app's own releases on github.com.
    var releasePageLink: URL? {
        if let releasePageURL { return ReleaseLink.validated(releasePageURL) }
        guard ReleaseLink.validated(downloadURL) != nil else { return nil }
        return URL(string: "https://github.com/mgwedd/aletheia/releases/tag/v\(version)")
            .flatMap(ReleaseLink.validated)
            ?? URL(string: "https://github.com/mgwedd/aletheia/releases")
    }
}

/// Which links from the update feed the app will open: https, github.com,
/// no credentials or port, and a path inside this app's own repository.
enum ReleaseLink {
    static let host = "github.com"
    static let pathPrefix = "/mgwedd/aletheia/"

    static func validated(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == host,
              url.user == nil, url.password == nil, url.port == nil,
              url.path.hasPrefix(pathPrefix),
              !url.pathComponents.contains("..")
        else { return nil }
        return url
    }
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
