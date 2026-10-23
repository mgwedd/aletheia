import XCTest
import SwiftUI
import AppKit
@testable import Aletheia

@MainActor
final class ExportResultAlertTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testAWrittenFileIsSavedAtItsURL() throws {
        let url = folder.appendingPathComponent("Note.pdf")
        XCTAssertEqual(FileSaver.write(Data("x".utf8), to: url), .saved(url))
        XCTAssertEqual(try Data(contentsOf: url), Data("x".utf8))
    }

    func testAFailedWriteSaysWhichFile() {
        let url = folder.appendingPathComponent("missing/Note.pdf")
        guard case let .failed(message) = FileSaver.write(Data("x".utf8), to: url) else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(message.hasPrefix("Note.pdf couldn't be saved."), message)
    }

    func testACancelledSaveShowsNothing() {
        XCTAssertNil(SaveOutcome.cancelled.shown)
        XCTAssertEqual(SaveOutcome.failed("x").shown, .failed("x"))
    }

    func testThePathShortensTheHomeFolder() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Note.pdf")
        XCTAssertEqual(ExportFileLink.displayPath(url), "~/Documents/Note.pdf")
    }

    func testClickingThePathOpensTheFileAndCloses() throws {
        let url = folder.appendingPathComponent("Note.docx")
        var opened: [URL] = []
        var dismissed = 0
        let hosting = NSHostingView(rootView: ExportResultAlert(
            outcome: .saved(url), onDismiss: { dismissed += 1 }, open: { opened.append($0) }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        // The path sits under the "Exported" heading; click down the left edge until it opens.
        for fromTop in stride(from: 30, through: 110, by: 4) where opened.isEmpty {
            let point = NSPoint(x: 40, y: hosting.bounds.height - CGFloat(fromTop))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(opened, [url])
        XCTAssertEqual(dismissed, 1)
    }

    func testEveryFileExportShowsTheResult() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Views")
        for file in ["SessionDetailView.swift", "SettingsView.swift"] {
            let source = try String(contentsOf: views.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(source.contains(".exportResultAlert($exportResult)"), file)
            XCTAssertTrue(source.contains("exportResult = outcome.shown"), file)
        }
        let toast = try String(contentsOf: views.appendingPathComponent("ExportStatusToast.swift"), encoding: .utf8)
        XCTAssertTrue(toast.contains("ExportFileLink(url: url)"), "the records zip links its path too")
    }
}
