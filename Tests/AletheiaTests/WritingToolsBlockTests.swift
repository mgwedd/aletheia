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

    func testPatientTextViewSubclassesInheritTheBlock() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("writingToolsBehavior needs macOS 15") }
        final class Probe: PatientTextView {}
        XCTAssertEqual(Probe(frame: .zero).writingToolsBehavior, .none)
        XCTAssertEqual(Probe(frame: .zero, textContainer: nil).writingToolsBehavior, .none)
    }

    // MARK: Source assertions

    /// The Theme kit is the only place raw text APIs may appear.
    private let kitDirectory = "Sources/App/Views/Theme/"

    /// Files that hold no patient data and may use the raw APIs.
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

    /// Raw text APIs, each with the kit replacement named in the failure.
    private let rawAPIs: [(pattern: String, use: String)] = [
        (#"(?<![A-Za-z])TextField\("#, "ThemeTextField or TextField.patient"),
        (#"(?<![A-Za-z])TextEditor\("#, "ThemeTextArea"),
        (#"(?<![A-Za-z])SecureField\("#, "a Theme secure field"),
        (#"\.textSelection\(\.enabled"#, ".selectablePatientText()"),
        (#"class\s+\w+\s*:\s*NSTextView\b"#, "a PatientTextView subclass"),
        (#"(?<![A-Za-z])NSTextView\((frame|usingTextLayoutManager)"#, "a PatientTextView subclass"),
        (#"scrollableTextView\(|scrollablePlainDocumentContentTextView\("#, "a PatientTextView subclass"),
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

    func testRawAPIPatternsCatchTheirTargets() {
        let samples = [
            #"TextField("Name", text: $name)"#, #"TextEditor(text: $t)"#, #"SecureField("", text: $p)"#,
            ".textSelection(.enabled)", "final class Foo: NSTextView {", "let v = NSTextView(frame: .zero)",
            "NSTextView.scrollableTextView()",
        ]
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
