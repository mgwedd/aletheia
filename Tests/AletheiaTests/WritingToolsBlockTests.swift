import XCTest
import AppKit
@testable import Aletheia

/// System Writing Tools stay off on every text surface that shows or edits
/// patient data. The behaviour tests build each `NSTextView` subclass; the
/// source tests stop a new field from shipping without the helper.
@MainActor
final class WritingToolsBlockTests: XCTestCase {
    private var repo: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    private func appSources() throws -> [(path: String, text: String)] {
        let root = repo.appendingPathComponent("Sources/App")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return try files.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { ($0.path.replacingOccurrences(of: repo.path + "/", with: ""), try String(contentsOf: $0, encoding: .utf8)) }
    }

    // MARK: Behaviour

    func testEveryTextViewSubclassTurnsWritingToolsOff() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("writingToolsBehavior needs macOS 15") }
        let frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let views: [(String, NSTextView)] = [
            ("ThemeTextAreaTextView", ThemeTextAreaTextView(frame: frame)),
            ("NoteTextView", NoteTextView(frame: frame)),
            ("ClickReportingTextView", TranscriptTextView.ClickReportingTextView(frame: frame)),
        ]
        for (name, view) in views {
            XCTAssertEqual(view.writingToolsBehavior, .none, name)
        }
    }

    func testHelperTurnsAPlainTextViewOff() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("writingToolsBehavior needs macOS 15") }
        let view = NSTextView(frame: .zero)
        view.disableWritingTools()
        XCTAssertEqual(view.writingToolsBehavior, .none)
    }

    // MARK: Source assertions

    func testEveryNSTextViewSubclassCallsDisableWritingTools() throws {
        let pattern = try NSRegularExpression(pattern: #"class\s+\w+\s*:\s*NSTextView\b"#)
        var found = 0
        for (path, text) in try appSources() {
            let range = NSRange(text.startIndex..., in: text)
            guard pattern.firstMatch(in: text, range: range) != nil else { continue }
            found += 1
            XCTAssertTrue(text.contains("disableWritingTools()"), "\(path) declares an NSTextView subclass without disableWritingTools()")
        }
        XCTAssertGreaterThanOrEqual(found, 3)
    }

    /// Files that hold no patient data. Anything else with a text field, editor
    /// or selectable text must apply `noWritingTools`.
    private let notPatientData: [String: String] = [
        "Sources/App/Views/SettingsView.swift": "Ollama model tag, risk-phrase list and help text: app configuration, no patient data",
        "Sources/App/Views/EncryptionSettingsView.swift": "Passphrase secure fields; Writing Tools never act on secure input",
        "Sources/App/Views/DoctorView.swift": "Diagnostics text, no patient data",
        "Sources/App/Views/FirstRunView.swift": "Onboarding copy",
        "Sources/App/Views/ConsentGuideView.swift": "Static consent-guide copy",
        "Sources/App/Views/CallAudioDebugView.swift": "Audio device diagnostics",
        "Sources/App/Views/DamagedRecordsNotice.swift": "Error and file-path text for the user to copy, no record contents",
        "Sources/App/Views/UpdatePromptView.swift": "Release notes",
        "Sources/App/Views/DatabaseUnavailableBanner.swift": "Error and file-path text for the user to copy",
    ]

    func testFieldsAndSelectableTextApplyNoWritingTools() throws {
        // `ThemeTextField` and `ThemeTextArea` are covered by their own definitions (checked below),
        // so only the bare SwiftUI types count here.
        let bare = try NSRegularExpression(pattern: #"(?<![A-Za-z])(TextField|TextEditor)\("#)
        for (path, text) in try appSources() {
            if notPatientData[path] != nil { continue }
            let usesField = bare.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            guard usesField || text.contains(".textSelection(.enabled)") else { continue }
            XCTAssertTrue(text.contains(".noWritingTools()"), "\(path) shows or edits text without .noWritingTools()")
        }
    }

    func testSharedComponentsCoverTheirCallers() throws {
        XCTAssertTrue(try source("Sources/App/Views/Theme/ThemeTextField.swift").contains(".noWritingTools()"))
        XCTAssertTrue(try source("Sources/App/Views/Theme/ThemeTextArea.swift").contains("disableWritingTools()"))
    }

    func testAllowlistEntriesExist() {
        for path in notPatientData.keys {
            XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent(path).path), path)
        }
    }
}
