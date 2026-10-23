import XCTest
@testable import Aletheia

/// Model-written text is shown as inert text: no live link, no remote image.
final class InertMarkdownTests: XCTestCase {
    func testLinksKeepTheirWordsButNotTheirTarget() throws {
        let text = try XCTUnwrap(InertMarkdown.inline("See [the notes](https://example.com/x) and <https://example.com/y> **now**"))
        for run in text.runs {
            XCTAssertNil(run.link)
            XCTAssertNil(run.imageURL)
        }
        let plain = String(text.characters)
        XCTAssertTrue(plain.contains("the notes"))
        XCTAssertFalse(plain.contains("example.com/x"))
    }

    func testImagesLoadNothing() throws {
        let text = try XCTUnwrap(InertMarkdown.inline("![tracker](https://example.com/pixel.png) after"))
        for run in text.runs {
            XCTAssertNil(run.imageURL)
            XCTAssertNil(run.link)
        }
    }

    /// No view renders a remote image or web content, and model text only
    /// reaches the screen through the inert path.
    func testNoRemoteLoadsInViews() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let views = root.appendingPathComponent("Sources/App/Views")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil))
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for banned in ["AsyncImage", "WKWebView", "WebView(", "NSImage(contentsOf: URL", "Data(contentsOf: URL(string"] {
                XCTAssertFalse(source.contains(banned), "\(banned) in \(file.lastPathComponent)")
            }
            if file.lastPathComponent != "MarkdownMessageView.swift" {
                XCTAssertFalse(source.contains("AttributedString(markdown:"), file.lastPathComponent)
            }
        }
    }
}
