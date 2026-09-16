import Foundation

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

    static func save(url: URL, key: String) throws {
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: key)
        stopAccessing()
        _ = url.startAccessingSecurityScopedResource()
        accessedURL = url
    }

    static func resolve(key: String) -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        stopAccessing()
        guard url.startAccessingSecurityScopedResource() else { return nil }
        accessedURL = url

        if isStale, let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(refreshed, forKey: key)
        }
        return url
    }

    private static func stopAccessing() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }
}
