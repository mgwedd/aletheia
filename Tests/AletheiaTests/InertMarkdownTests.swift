import XCTest
@testable import Aletheia

/// Model-written text is shown as inert text: no live link, no remote image,
/// and no view that loads remote content.
final class InertMarkdownTests: XCTestCase {
    func testImagesLoadNothing() throws {
        let text = try XCTUnwrap(SafeMarkdown.attributed(from: "![tracker](https://example.com/pixel.png) after"))
        for run in text.runs {
            XCTAssertNil(run.imageURL)
            XCTAssertNil(run.link)
        }
        XCTAssertFalse(String(text.characters).contains("example.com"))
    }

    func testNoRemoteLoadsInViews() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let views = root.appendingPathComponent("Sources/App/Views")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil))
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for banned in ["AsyncImage", "WKWebView", "NSImage(contentsOf: URL", "Data(contentsOf: URL(string",
                           "isAutomaticLinkDetectionEnabled = true"] {
                XCTAssertFalse(source.contains(banned), "\(banned) in \(file.lastPathComponent)")
            }
        }
    }
}
