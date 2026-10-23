import AppKit
import XCTest
@testable import Aletheia

@MainActor
final class PHIPasteboardTests: XCTestCase {
    func testStringIsConcealedTransientAndReplacesOldContents() {
        let pasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("old", forType: .string)

        PHIPasteboard.writeString("patient text", to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "patient text")
        XCTAssertNotNil(pasteboard.data(forType: PHIPasteboard.concealed))
        XCTAssertNotNil(pasteboard.data(forType: PHIPasteboard.transient))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    }

    func testSelectionPreservesNormalTextViewPayloadWithMarkers() {
        let pasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let textView = NoteTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = "clinical note"
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))

        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), "clinical note")
        XCTAssertNotNil(pasteboard.data(forType: PHIPasteboard.concealed))
        XCTAssertNotNil(pasteboard.data(forType: PHIPasteboard.transient))
    }

    func testGeneralPasteboardIsLimitedToHelper() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sourceRoot = root.appendingPathComponent("Sources/App")
        let allowed = Set(["Services/PHIPasteboard.swift"])
        let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)!
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let relative = file.path.replacingOccurrences(of: sourceRoot.path + "/", with: "")
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("NSPasteboard.general") || source.contains("NSPasteboard = .general") {
                XCTAssertTrue(allowed.contains(relative), "Unexpected general pasteboard in \(relative)")
            }
        }
    }
}
