import XCTest
import AppKit
import SwiftUI
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

    func testPatientTextViewSubclassesInheritTheBlock() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("writingToolsBehavior needs macOS 15") }
        final class Probe: PatientTextView {}
        XCTAssertEqual(Probe(frame: .zero).writingToolsBehavior, .none)
        XCTAssertEqual(Probe(frame: .zero, textContainer: nil).writingToolsBehavior, .none)
    }

    /// SwiftUI text fields edit through the window's shared field editor; the
    /// block has to reach it while the field is being edited.
    private func fieldEditorBehavior<V: View>(editing content: V, placeholder: String) throws -> NSTextView {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: content.frame(width: 400, height: 120))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        let field = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == placeholder || $0.placeholderAttributedString?.string == placeholder
        }, "no field with placeholder \(placeholder)")
        XCTAssertTrue(window.makeFirstResponder(field))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        return editor
    }

    func testPatientFieldsEditWithWritingToolsOff() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("writingToolsBehavior needs macOS 15") }
        struct Patient: View {
            @State var text = ""
            var body: some View { TextField.patient("Patient field", text: $text) }
        }
        struct Focused: View {
            @State var text = ""
            @FocusState var focused: Bool
            var body: some View { TextField.patient("Focused field", text: $text, focus: $focused) }
        }
        struct Themed: View {
            @State var text = ""
            var body: some View { ThemeTextField(placeholder: "Themed field", text: $text) }
        }
        XCTAssertEqual(try fieldEditorBehavior(editing: Patient(), placeholder: "Patient field").writingToolsBehavior, .none)
        XCTAssertEqual(try fieldEditorBehavior(editing: Focused(), placeholder: "Focused field").writingToolsBehavior, .none)
        XCTAssertEqual(try fieldEditorBehavior(editing: Themed(), placeholder: "Themed field").writingToolsBehavior, .none)
    }

    /// Control: without the block the field editor keeps Writing Tools, so the
    /// test above is measuring the block and not a default.
    func testAPlainFieldEditsWithWritingToolsOn() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("writingToolsBehavior needs macOS 15") }
        struct Plain: View {
            @State var text = ""
            var body: some View { TextField("Plain field", text: $text) }
        }
        XCTAssertNotEqual(try fieldEditorBehavior(editing: Plain(), placeholder: "Plain field").writingToolsBehavior, .none)
    }

    // MARK: Source assertions

    /// The Theme kit is the only place raw text APIs may appear.
    private let kitDirectory = "Sources/App/Views/Theme/"

    /// Files that hold no patient data and may use the raw APIs.
    private let notPatientData: [String: String] = [
        "Sources/App/Views/SettingsView.swift": "Risk-phrase list and help text: app configuration, no patient data",
        "Sources/App/Views/EncryptionSettingsView.swift": "Passphrase secure fields; Writing Tools never act on secure input",
        "Sources/App/Views/DoctorView.swift": "Diagnostics text, no patient data",
        "Sources/App/Views/FirstRunView.swift": "Onboarding copy",
        "Sources/App/Views/ConsentGuideView.swift": "Static consent-guide copy",
        "Sources/App/Views/CallAudioDebugView.swift": "Audio device diagnostics",
        "Sources/App/Views/DamagedRecordsNotice.swift": "Error and file-path text for the user to copy, no record contents",
        "Sources/App/Views/UpdatePromptView.swift": "Release notes",
        "Sources/App/Views/DatabaseUnavailableBanner.swift": "Error and file-path text for the user to copy",
        "Sources/App/Views/FolderUnlockView.swift": "Recovery-key entry: needs autocorrection off, which the kit's text area lacks; Writing Tools are off with .noWritingTools()",
    ]

    /// Raw text APIs, each with the kit replacement named in the failure.
    private let rawAPIs: [(pattern: String, use: String)] = [
        (#"(?<![A-Za-z])TextField\("#, "ThemeTextField or TextField.patient"),
        (#"(?<![A-Za-z])TextEditor\("#, "ThemeTextArea"),
        (#"(?<![A-Za-z])SecureField\("#, "a Theme secure field"),
        (#"\.textSelection\(\.enabled"#, ".selectablePatientText()"),
        (#"class\s+\w+\s*:\s*NSTextView\b"#, "a PatientTextView subclass"),
        (#"(?<![A-Za-z])NSTextView(\.init)?\((frame|usingTextLayoutManager|\))"#, "a PatientTextView subclass"),
        (#"scrollableTextView\(|scrollablePlainDocumentContentTextView\("#, "a PatientTextView subclass"),
        (#"(?<![A-Za-z])(NS(Secure)?TextField|NSSearchField)(\.init)?\("#, "ThemeTextField or TextField.patient"),
        (#"\.searchable\("#, "GlobalSearchField"),
    ]

    func testRawTextAPIsOnlyAppearInTheThemeKit() throws {
        var violations: [String] = []
        for (path, text) in try appSources() where !path.hasPrefix(kitDirectory) && notPatientData[path] == nil {
            for line in text.components(separatedBy: "\n") {
                let code = line.components(separatedBy: "//").first ?? ""
                for api in rawAPIs where code.range(of: api.pattern, options: .regularExpression) != nil {
                    violations.append("\(path): `\(line.trimmingCharacters(in: .whitespaces))` — use \(api.use)")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty, "Patient text must go through the Theme kit:\n" + violations.joined(separator: "\n"))
    }

    /// The recovery-key editor is allowlisted only because it needs autocorrection
    /// off; it must still turn Writing Tools off itself.
    func testRecoveryKeyEditorTurnsWritingToolsOff() throws {
        let text = try source("Sources/App/Views/FolderUnlockView.swift")
        XCTAssertTrue(text.contains("TextEditor(text: $recoveryKey)"))
        XCTAssertTrue(text.contains(".noWritingTools()"))
        XCTAssertTrue(text.contains(".autocorrectionDisabled()"))
    }

    func testRawAPIPatternsCatchTheirTargets() {
        let samples = [
            #"TextField("Name", text: $name)"#, #"TextEditor(text: $t)"#, #"SecureField("", text: $p)"#,
            ".textSelection(.enabled)", "final class Foo: NSTextView {", "let v = NSTextView(frame: .zero)",
            "NSTextView.scrollableTextView()", #"let f = NSTextField(string: "")"#, ".searchable(text: $q)",
        ]
        for sample in ["NSTextView()", "NSTextView.init(frame: r)", "NSSearchField(frame: r)", "NSSecureTextField()"] {
            XCTAssertTrue(rawAPIs.contains { sample.range(of: $0.pattern, options: .regularExpression) != nil }, sample)
        }
        for (sample, api) in zip(samples, rawAPIs) {
            XCTAssertNotNil(sample.range(of: api.pattern, options: .regularExpression), sample)
        }
        for allowed in [#"ThemeTextField(placeholder: "x", text: $x)"#, #"TextField.patient("Title", text: $t)"#, "final class Foo: PatientTextView {"] {
            XCTAssertFalse(rawAPIs.contains { allowed.range(of: $0.pattern, options: .regularExpression) != nil }, allowed)
        }
    }

    func testKitComponentsApplyTheBlock() throws {
        let kit = try source("Sources/App/Views/Theme/ThemeWritingTools.swift")
        XCTAssertTrue(kit.contains("class PatientTextView: NSTextView"))
        XCTAssertEqual(kit.components(separatedBy: "disableWritingTools()").count - 1, 4, "the helper plus one call in each PatientTextView initializer")
        XCTAssertTrue(kit.contains("textSelection(.enabled).noWritingTools()"))
        XCTAssertTrue(try source("Sources/App/Views/Theme/ThemeTextField.swift").contains(".noWritingTools()"))
        XCTAssertTrue(try source("Sources/App/Views/Theme/ThemeTextArea.swift").contains(": PatientTextView"))
        // Other kit files may use raw APIs only if they apply the block themselves.
        for (path, text) in try appSources() where path.hasPrefix(kitDirectory) && !path.hasSuffix("ThemeWritingTools.swift") {
            let raw = rawAPIs.contains { text.range(of: $0.pattern, options: .regularExpression) != nil }
            if raw {
                XCTAssertTrue(text.contains(".noWritingTools()") || text.contains("PatientTextView"), "\(path) uses a raw text API without the block")
            }
        }
    }

    func testEveryWindowRootAppliesTheBlock() throws {
        let app = try source("Sources/App/AletheiaApp.swift")
        let roots = app.components(separatedBy: "\n").filter {
            $0.range(of: #"^\s*(WindowGroup|Window|Settings|MenuBarExtra)\b.*\{"#, options: .regularExpression) != nil
                || $0.contains(".sheet(")
        }.count
        let applied = app.components(separatedBy: ".noWritingTools()").count - 1
        XCTAssertGreaterThanOrEqual(roots, 6)
        XCTAssertGreaterThanOrEqual(applied, roots, "every scene root and app-level sheet applies .noWritingTools()")
    }

    func testAllowlistEntriesExist() {
        for path in notPatientData.keys {
            XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent(path).path), path)
        }
    }
}
