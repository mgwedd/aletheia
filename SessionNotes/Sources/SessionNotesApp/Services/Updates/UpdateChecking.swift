import Foundation

/// One published release, as described by the update feed.
struct ReleaseInfo: Decodable, Equatable {
    let version: String
    let downloadURL: URL
    let releaseNotes: String
    let minimumSystemVersion: String?
    let publishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case version
        case downloadURL
        case releaseNotes
        case minimumSystemVersion
        case publishedAt
    }
}

/// The update-source integration (another adapter seam). The default
/// implementation polls a small JSON feed; it could just as well read a
/// Sparkle-style appcast or a different endpoint without changing the
/// service or UI above it.
protocol UpdateChecking {
    func fetchLatest() async throws -> ReleaseInfo
}

/// Fetches and decodes a JSON release manifest from a URL. The feed is
/// expected to describe the single latest release:
///
///     { "version": "1.1.0",
///       "downloadURL": "https://.../SessionNotes-1.1.0.dmg",
///       "releaseNotes": "…",
///       "minimumSystemVersion": "14.0",
///       "publishedAt": "2026-09-16T00:00:00Z" }
struct AppcastUpdateChecker: UpdateChecking {
    let feedURL: URL
    var session: URLSession = .shared

    func fetchLatest() async throws -> ReleaseInfo {
        var request = URLRequest(url: feedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ReleaseInfo.self, from: data)
    }
}
