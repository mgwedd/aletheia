import XCTest
@testable import Aletheia

/// The third-party notices and the per-model licenses. The notices file at the
/// repo root is the source; the app bundles a copy, and every model and pinned
/// package must be named in it.
final class ThirdPartyNoticesTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func repoNotices() throws -> String {
        try String(contentsOf: root.appendingPathComponent("THIRD-PARTY-NOTICES.md"), encoding: .utf8)
    }

    // MARK: - Settings shows the repo file

    func testBundledNoticesEqualTheRepoRootFile() throws {
        let bundled = try XCTUnwrap(ThirdPartyNotices.load(), "THIRD-PARTY-NOTICES.md is not in the app bundle (project.yml)")
        XCTAssertEqual(bundled, try repoNotices())
    }

    func testLicensesPaneIsInTheSidebar() {
        XCTAssertEqual(SettingsPane.licenses.title, "Licenses")
        XCTAssertTrue(SettingsPane.available(encryptionOffered: false).contains(.licenses))
        XCTAssertTrue(SettingsPane.available(encryptionOffered: true, hasSetAsideRecordings: false).contains(.licenses))
    }

    func testSettingsViewShowsTheLicensesPane() throws {
        let source = try String(contentsOf: root.appendingPathComponent("Sources/App/Views/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("case .licenses: LicensesPane()"))
    }

    func testProjectBundlesTheNoticesFile() throws {
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(project.contains("path: THIRD-PARTY-NOTICES.md"))
    }

    func testNoticesAreCompleteNotPlaceholders() throws {
        let text = try repoNotices()
        XCTAssertTrue(text.contains("Permission is hereby granted, free of charge"), "the MIT text is reproduced in full")
        XCTAssertTrue(text.contains("Copyright (c) 2023-2026 The ggml authors"))
    }

    // MARK: - Document blocks

    func testBlocksCoverHeadingsBulletsParagraphsAndFences() {
        let text = "# Title\n\nFirst line\nsecond line.\n\n- item one\n```text\nMIT\n\nlicense\n```\n## Next\n"
        XCTAssertEqual(ThirdPartyNotices.blocks(from: text), [
            .heading(level: 1, text: "Title"),
            .paragraph("First line second line."),
            .bullet("item one"),
            .code("MIT\n\nlicense"),
            .heading(level: 2, text: "Next")
        ])
    }

    func testHashWithoutSpaceIsNotAHeading() {
        XCTAssertEqual(ThirdPartyNotices.blocks(from: "#tag"), [.paragraph("#tag")])
    }

    func testEveryLineOfTheRealFileIsShown() throws {
        let text = try repoNotices()
        let shown = ThirdPartyNotices.blocks(from: text).map { block -> String in
            switch block {
            case .heading(_, let t), .bullet(let t), .code(let t): return t
            case .paragraph(let t): return t
            }
        }.joined(separator: "\n")
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") { inFence.toggle(); continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !inFence else { continue }
            let content = trimmed.replacingOccurrences(of: #"^(#{1,6} |- )"#, with: "", options: .regularExpression)
            XCTAssertTrue(shown.contains(content), "not shown: \(content)")
        }
    }

    func testLinkifyMakesAddressesTappableWithoutTrailingPunctuation() throws {
        let attributed = ThirdPartyNotices.linkified("See https://example.com/a/b. Then `code`.")
        let links = attributed.runs.compactMap(\.link)
        XCTAssertEqual(links, [try XCTUnwrap(URL(string: "https://example.com/a/b"))])
    }

    // MARK: - Every model has a license

    func testEveryModelHasAHTTPSLicenseAndName() {
        for model in LlamaModel.allCases {
            XCTAssertFalse(model.licenseName.trimmingCharacters(in: .whitespaces).isEmpty, "\(model)")
            XCTAssertEqual(model.licenseURL.scheme, "https", "\(model)")
            XCTAssertNotNil(model.licenseURL.host, "\(model)")
            if let use = model.acceptableUseURL { XCTAssertEqual(use.scheme, "https") }
        }
        for model in WhisperModel.allCases {
            XCTAssertFalse(model.licenseName.trimmingCharacters(in: .whitespaces).isEmpty, "\(model)")
            XCTAssertEqual(model.licenseURL.scheme, "https", "\(model)")
            XCTAssertNotNil(model.licenseURL.host, "\(model)")
        }
    }

    func testLlamaCarriesBuiltWithLlamaAndItsUsePolicy() {
        XCTAssertEqual(LlamaModel.llama31_8b.attribution, "Built with Llama")
        XCTAssertNotNil(LlamaModel.llama31_8b.acceptableUseURL)
        XCTAssertTrue(LlamaModel.llama31_8b.licenseSummary.contains("Built with Llama"))
        XCTAssertTrue(LlamaModel.llama31_8b.licenseSummary.contains(LlamaModel.llama31_8b.licenseURL.absoluteString))
        XCTAssertNil(LlamaModel.gemma4_e2b.attribution)
    }

    func testGemmaIsOfferedUnderApache2() {
        XCTAssertEqual(LlamaModel.gemma4_e2b.licenseName, "Apache License 2.0")
    }

    func testMedicalModelsCarryTheirLicensesAndPolicies() {
        XCTAssertEqual(LlamaModel.medgemma15_4b.licenseName, "Health AI Developer Foundations Terms")
        XCTAssertEqual(LlamaModel.medgemma_27b.licenseName, "Health AI Developer Foundations Terms")
        XCTAssertEqual(
            LlamaModel.medgemma15_4b.licenseURL.absoluteString,
            "https://developers.google.com/health-ai-developer-foundations/terms"
        )
        XCTAssertEqual(LlamaModel.medgemma_27b.licenseURL, LlamaModel.medgemma15_4b.licenseURL)
        XCTAssertNotNil(LlamaModel.medgemma15_4b.acceptableUseURL)
        XCTAssertEqual(LlamaModel.medgemma_27b.acceptableUseURL, LlamaModel.medgemma15_4b.acceptableUseURL)
    }

    // MARK: - The notices name every model and package

    func testEveryModelIsNamedInTheNotices() throws {
        let text = try repoNotices()
        for model in LlamaModel.allCases {
            XCTAssertTrue(text.contains(model.fileName), "\(model.fileName) is not in THIRD-PARTY-NOTICES.md")
            XCTAssertTrue(text.contains(model.shortName), "\(model.shortName) is not in THIRD-PARTY-NOTICES.md")
            XCTAssertTrue(text.contains(model.licenseURL.absoluteString), "\(model.licenseName) link is not in THIRD-PARTY-NOTICES.md")
            if let use = model.acceptableUseURL { XCTAssertTrue(text.contains(use.absoluteString)) }
            if let attribution = model.attribution { XCTAssertTrue(text.contains(attribution)) }
        }
        for model in WhisperModel.allCases {
            XCTAssertTrue(text.contains(model.fileName), "\(model.fileName) is not in THIRD-PARTY-NOTICES.md")
            XCTAssertTrue(text.contains(model.licenseURL.absoluteString))
        }
    }

    func testEveryPinnedPackageHasASection() throws {
        let packages = root.appendingPathComponent("Packages")
        let names = try FileManager.default.contentsOfDirectory(atPath: packages.path)
            .filter { FileManager.default.fileExists(atPath: packages.appendingPathComponent($0).appendingPathComponent("Package.swift").path) }
        XCTAssertFalse(names.isEmpty, "no packages found under Packages/")
        let text = try repoNotices()
        for dir in names {
            let manifest = try String(contentsOf: packages.appendingPathComponent(dir).appendingPathComponent("Package.swift"), encoding: .utf8)
            let package = try XCTUnwrap(firstMatch(#"name:\s*"([^"]+)""#, in: manifest), "\(dir): no package name")
            let url = try XCTUnwrap(firstMatch(#"url:\s*"([^"]+)""#, in: manifest), "\(dir): no pinned url")
            let tag = try XCTUnwrap(firstMatch(#"/download/([^/]+)/"#, in: url), "\(dir): no build tag in \(url)")
            XCTAssertTrue(text.contains("- Package: `\(package)`"), "\(package) has no section in THIRD-PARTY-NOTICES.md")
            XCTAssertTrue(text.contains("build \(tag)"), "\(package) is pinned at \(tag), which THIRD-PARTY-NOTICES.md does not name")
        }
    }

    func testEveryBundledModelFileIsNamedInTheNotices() throws {
        // A binary asset checked into the sources must be credited too.
        let sources = root.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let text = try repoNotices()
        for case let url as URL in enumerator where ["bin", "gguf", "mlmodel", "onnx"].contains(url.pathExtension) {
            XCTAssertTrue(text.contains(url.lastPathComponent), "\(url.lastPathComponent) is not in THIRD-PARTY-NOTICES.md")
        }
    }

    // MARK: - Every download offer shows the license

    func testEveryDownloadOfferShowsTheModelLicense() throws {
        let views = root.appendingPathComponent("Sources/App/Views")
        func source(_ name: String) throws -> String { try String(contentsOf: views.appendingPathComponent(name), encoding: .utf8) }
        let settings = try source("SettingsView.swift")
        XCTAssertTrue(settings.contains("ModelLicenseLink(settings.whisperModel)"))
        XCTAssertTrue(settings.contains("ModelLicenseLink(settings.llamaModel)"))
        let setup = try source("SetupChecklistView.swift")
        XCTAssertTrue(setup.contains("ModelLicenseLink(settings.whisperModel)"))
        XCTAssertTrue(setup.contains("ModelLicenseLink(settings.llamaModel)"))
        let engine = try source("AIEngineProblemAlert.swift")
        XCTAssertTrue(engine.contains("ModelLicenseLink(integrations.llamaModel)"))
        XCTAssertTrue(engine.contains("llamaModel.licenseSummary"))
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
