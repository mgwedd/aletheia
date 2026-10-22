import XCTest
@testable import Aletheia

final class AppSettingsOllamaURLTests: XCTestCase {
    private let key = "ollamaBaseURL"
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "AppSettingsOllamaURLTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testInvalidStoredValueFallsBackAndIsRemoved() {
        defaults.set("http://example.com:11434", forKey: key)
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.ollamaBaseURL, LoopbackURL.defaultOllama)
        XCTAssertNil(defaults.object(forKey: key))
    }

    func testValidStoredValueIsKept() {
        defaults.set("http://localhost:9999", forKey: key)
        XCTAssertEqual(AppSettings(defaults: defaults).ollamaBaseURL.absoluteString, "http://localhost:9999")
        XCTAssertEqual(defaults.string(forKey: key), "http://localhost:9999")
    }

    func testSettingARemoteURLResetsItAndClearsTheStoredValue() {
        let settings = AppSettings(defaults: defaults)
        settings.ollamaBaseURL = URL(string: "http://127.0.0.1:1234")!
        XCTAssertEqual(defaults.string(forKey: key), "http://127.0.0.1:1234")
        settings.ollamaBaseURL = URL(string: "http://10.0.0.5:11434")!
        XCTAssertEqual(settings.ollamaBaseURL, LoopbackURL.defaultOllama)
        XCTAssertNil(defaults.object(forKey: key))
    }
}
