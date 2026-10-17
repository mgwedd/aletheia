import XCTest
@testable import Aletheia

final class LlamaModelTests: XCTestCase {
    func testCatalogIsWellFormed() {
        for model in LlamaModel.allCases {
            XCTAssertFalse(model.displayName.isEmpty)
            XCTAssertFalse(model.shortName.isEmpty)
            XCTAssertGreaterThan(model.approximateSizeMB, 0)
            XCTAssertTrue(model.fileName.hasSuffix(".gguf"))
            XCTAssertEqual(model.downloadURL.scheme, "https")
            XCTAssertEqual(LlamaModel(rawValue: model.rawValue), model)
        }
    }

    func testEveryModelHasA64CharLowercaseHexPin() {
        for model in LlamaModel.allCases {
            XCTAssertNotNil(model.expectedSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression),
                            "\(model.rawValue) needs a SHA-256 pin")
        }
    }

    func testDownloadURLsArePinnedToACommit() {
        for model in LlamaModel.allCases {
            XCTAssertNotNil(model.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression))
            let url = model.downloadURL.absoluteString
            XCTAssertTrue(url.contains("/resolve/\(model.revision)/\(model.fileName)"), url)
            XCTAssertFalse(url.contains("/resolve/main/"), url)
            XCTAssertTrue(url.hasPrefix("https://huggingface.co/ggml-org/"), url)
        }
    }

    /// AppSettings loads with `LlamaModel(rawValue:) ?? .recommended(for:)`, so a
    /// persisted raw value from a retired model must not resolve (and not crash).
    func testRetiredRawValuesFallBackToRecommended() {
        for legacy in ["llama-3.2-1b-instruct-q4_k_m", "llama-3.2-3b-instruct-q4_k_m"] {
            XCTAssertNil(LlamaModel(rawValue: legacy))
            XCTAssertEqual(LlamaModel(rawValue: legacy) ?? .recommended(for: Self.mac(gb: 16)), .llama31_8b)
        }
    }

    private static func mac(gb: Int) -> HardwareCapabilities {
        HardwareCapabilities(isAppleSilicon: true, physicalMemoryGB: gb, coreCount: 8, chipDescription: "Test")
    }

    func testRecommendedFollowsMemory() {
        XCTAssertEqual(LlamaModel.recommended(for: Self.mac(gb: 8)), .gemma4_e2b)
        XCTAssertEqual(LlamaModel.recommended(for: Self.mac(gb: 15)), .gemma4_e2b)
        XCTAssertEqual(LlamaModel.recommended(for: Self.mac(gb: 16)), .llama31_8b)
        XCTAssertEqual(LlamaModel.recommended(for: Self.mac(gb: 64)), .llama31_8b)
    }

    func testFileNamesAreUnique() {
        let names = LlamaModel.allCases.map(\.fileName)
        XCTAssertEqual(Set(names).count, names.count)
    }
}

final class LlamaRuntimeTests: XCTestCase {
    func testModelURLIsUnderModelsDirectoryWithFileName() {
        let url = LlamaRuntime.modelURL(for: .llama31_8b)
        XCTAssertEqual(url.lastPathComponent, LlamaModel.llama31_8b.fileName)
        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent == "Models")
    }
}

final class LlamaInstallVerifiedTests: XCTestCase {
    private func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func testMismatchKeepsExistingGoodModelAndRemovesPartial() throws {
        let dir = try tmpDir()
        let dest = dir.appendingPathComponent("m.gguf")
        let download = dir.appendingPathComponent("tmp-download")
        try Data("good".utf8).write(to: dest)
        try Data("bad".utf8).write(to: download)
        XCTAssertThrowsError(try LlamaModelDownloader.installVerified(
            from: download, to: dest, expectedSHA256: String(repeating: "0", count: 64)))
        XCTAssertEqual(try Data(contentsOf: dest), Data("good".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: LlamaModelDownloader.partialURL(for: dest).path))
    }

    func testMatchReplacesExistingAndLeavesNoPartial() throws {
        let dir = try tmpDir()
        let dest = dir.appendingPathComponent("m.gguf")
        let download = dir.appendingPathComponent("tmp-download")
        try Data("old".utf8).write(to: dest)
        try Data("new".utf8).write(to: download)
        let sha = try ModelDigest.sha256(ofFileAt: download)
        try LlamaModelDownloader.installVerified(from: download, to: dest, expectedSHA256: sha)
        XCTAssertEqual(try Data(contentsOf: dest), Data("new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: LlamaModelDownloader.partialURL(for: dest).path))
    }
}
