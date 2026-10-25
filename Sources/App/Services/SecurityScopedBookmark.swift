import Foundation
import os

private let log = Logger(subsystem: "com.aletheia", category: "Bookmark")

/// Persists sandbox access to a user-chosen folder across launches.
///
/// Under App Sandbox, picking a folder with NSOpenPanel only grants access
/// for the current process lifetime unless you capture a security-scoped
/// bookmark and re-resolve it on the next launch. This wraps that dance so
/// the rest of the app can just treat `AppSettings.dataRootURL` as a normal
/// folder URL.
enum SecurityScopedBookmark {
    /// Currently-open resource, kept so we can balance start/stop calls.
    private static var accessedURL: URL?

    static func save(url: URL, key: String, defaults: UserDefaults = .standard) throws {
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: key)
        stopAccessing()
        _ = url.startAccessingSecurityScopedResource()
        accessedURL = url
    }

    /// True when the last `resolve` found a stale bookmark and couldn't refresh
    /// it. The folder is still returned and usable now, but access may not
    /// survive the next launch, so the folder should be chosen again.
    private(set) static var lastRefreshFailed = false

    /// The system calls `resolve` makes, replaceable in tests.
    struct Operations {
        var resolveData: (Data) throws -> (url: URL, isStale: Bool)
        var startAccessing: (URL) -> Bool
        var makeBookmark: (URL) throws -> Data

        static let system = Operations(
            resolveData: { data in
                var isStale = false
                let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
                return (url, isStale)
            },
            startAccessing: { $0.startAccessingSecurityScopedResource() },
            makeBookmark: { try $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
        )
    }

    static func resolve(key: String, defaults: UserDefaults = .standard, operations: Operations = .system) -> URL? {
        lastRefreshFailed = false
        guard let bookmark = defaults.data(forKey: key) else { return nil }
        guard let (url, isStale) = try? operations.resolveData(bookmark) else { return nil }

        stopAccessing()
        guard operations.startAccessing(url) else { return nil }
        accessedURL = url

        if isStale {
            do {
                defaults.set(try operations.makeBookmark(url), forKey: key)
            } catch {
                lastRefreshFailed = true
                log.error("Couldn't refresh a stale folder bookmark: \(error.localizedDescription, privacy: .public)")
            }
        }
        return url
    }

    private static func stopAccessing() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }
}
