import XCTest
@testable import Aletheia

final class LoopbackURLTests: XCTestCase {
    func testAcceptsLoopbackAddresses() {
        for s in ["http://127.0.0.1:11434", "http://127.1.2.3:11434", "http://[::1]:11434", "http://localhost:11434"] {
            XCTAssertNotNil(LoopbackURL.validate(URL(string: s)!), s)
        }
    }

    func testRejectsEverythingElse() {
        for s in ["http://127.evil.example:11434", "http://localhost.evil:11434", "http://10.0.0.5:11434",
                  "https://127.0.0.1:11434", "http://user@127.0.0.1:11434", "http://user:pw@localhost:11434",
                  "http://127.0.0.1", "http://localhost", "http://[::2]:11434", "http://127.1:11434",
                  "http://localhost.:11434", "file:///tmp/x", "http:///nohost"] {
            XCTAssertNil(URL(string: s).flatMap(LoopbackURL.validate(_:)), s)
        }
        XCTAssertNil(LoopbackURL.validate("https://x"))
        XCTAssertNil(LoopbackURL.validate("not a url"))
    }

    func testStringOverloadTrimsWhitespace() {
        XCTAssertNotNil(LoopbackURL.validate(" http://127.0.0.1:11434\n"))
    }
}
