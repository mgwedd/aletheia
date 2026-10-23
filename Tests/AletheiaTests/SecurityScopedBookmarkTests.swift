import XCTest
@testable import Aletheia

final class SecurityScopedBookmarkTests: XCTestCase {
    private struct RefreshError: Error {}
    private let folder = URL(fileURLWithPath: "/tmp/bookmark-test-folder")

    private func defaults() -> UserDefaults {
        let name = "SecurityScopedBookmarkTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.set(Data("old".utf8), forKey: "k")
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func operations(stale: Bool, refresh: @escaping (URL) throws -> Data) -> SecurityScopedBookmark.Operations {
        .init(resolveData: { [folder] _ in (folder, stale) }, startAccessing: { _ in true }, makeBookmark: refresh)
    }

    func testStaleRefreshFailureIsDistinct() {
        let d = defaults()
        let url = SecurityScopedBookmark.resolve(key: "k", defaults: d, operations: operations(stale: true) { _ in throw RefreshError() })
        XCTAssertEqual(url, folder, "the folder is still returned")
        XCTAssertTrue(SecurityScopedBookmark.lastRefreshFailed)
        XCTAssertEqual(d.data(forKey: "k"), Data("old".utf8), "the old bookmark is kept")
    }

    func testStaleRefreshSuccessIsStoredAndNotFlagged() {
        let d = defaults()
        let url = SecurityScopedBookmark.resolve(key: "k", defaults: d, operations: operations(stale: true) { _ in Data("new".utf8) })
        XCTAssertEqual(url, folder)
        XCTAssertFalse(SecurityScopedBookmark.lastRefreshFailed)
        XCTAssertEqual(d.data(forKey: "k"), Data("new".utf8))
    }

    func testFreshBookmarkIsNotRefreshedOrFlagged() {
        let d = defaults()
        _ = SecurityScopedBookmark.resolve(key: "k", defaults: d, operations: operations(stale: true) { _ in throw RefreshError() })
        XCTAssertTrue(SecurityScopedBookmark.lastRefreshFailed)
        _ = SecurityScopedBookmark.resolve(key: "k", defaults: d, operations: operations(stale: false) { _ in throw RefreshError() })
        XCTAssertFalse(SecurityScopedBookmark.lastRefreshFailed, "each resolve starts clean")
    }
}
