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

    func testExpectedBytesMatchThePinnedSizes() {
        XCTAssertEqual(LlamaModel.llama31_8b.expectedBytes, 6_036_116_480)
        XCTAssertEqual(LlamaModel.gemma4_e2b.expectedBytes, 2_841_481_184)
        XCTAssertEqual(LlamaModel.medgemma15_4b.expectedBytes, 2_489_894_976)
        XCTAssertEqual(LlamaModel.medgemma_27b.expectedBytes, 16_546_405_376)
        XCTAssertEqual(LlamaModel.apertus8b_meditronFO.expectedBytes, 5_057_886_624)
        for model in LlamaModel.allCases {
            XCTAssertEqual(Int64(model.approximateSizeMB), (model.expectedBytes + 500_000) / 1_000_000, "\(model)")
        }
    }

    func testDownloadURLsArePinnedToACommit() {
        for model in LlamaModel.allCases {
            XCTAssertNotNil(model.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression))
            let url = model.downloadURL.absoluteString
            XCTAssertTrue(url.contains("/resolve/\(model.revision)/\(model.fileName)"), url)
            XCTAssertFalse(url.contains("/resolve/main/"), url)
            XCTAssertTrue(url.hasPrefix("https://huggingface.co/"), url)
        }
    }

    /// AppSettings loads with `LlamaModel(rawValue:) ?? .recommended(for:)`, so a
    /// persisted raw value from a retired model must not resolve (and not crash).
    func testRetiredRawValuesFallBackToRecommended() {
        for legacy in ["llama-3.2-1b-instruct-q4_k_m", "llama-3.2-3b-instruct-q4_k_m",
                       "medllama-2-7b-q4_k_s", "medgemma-4b-it-q4_k_m"] {
            XCTAssertNil(LlamaModel(rawValue: legacy))
            XCTAssertEqual(LlamaModel(rawValue: legacy) ?? .recommended(for: Self.mac(gb: 16)), .medgemma15_4b)
        }
    }

    private static func mac(gb: Int) -> HardwareCapabilities {
        HardwareCapabilities(isAppleSilicon: true, physicalMemoryGB: gb, coreCount: 8, chipDescription: "Test")
    }

    func testRecommendedFollowsMemory() {
        XCTAssertEqual(LlamaModel.recommended(for: Self.mac(gb: 8)), .medgemma15_4b)
        XCTAssertEqual(LlamaModel.recommended(for: Self.mac(gb: 16)), .medgemma15_4b)
        XCTAssertEqual(LlamaModel.recommended(for: Self.mac(gb: 32)), .medgemma15_4b)
        XCTAssertEqual(LlamaModel.recommended(for: Self.mac(gb: 48)), .medgemma_27b)
        XCTAssertEqual(LlamaModel.recommended(for: Self.mac(gb: 64)), .medgemma_27b)
        let intel = HardwareCapabilities(isAppleSilicon: false, physicalMemoryGB: 64, coreCount: 8, chipDescription: "Intel")
        XCTAssertEqual(LlamaModel.recommended(for: intel), .medgemma15_4b)
    }

    func testMedGemmaSizeFollowsMemory() {
        XCTAssertEqual(LlamaModel.medGemma(for: Self.mac(gb: 8)), .medgemma15_4b)
        XCTAssertEqual(LlamaModel.medGemma(for: Self.mac(gb: 16)), .medgemma15_4b)
        XCTAssertEqual(LlamaModel.medGemma(for: Self.mac(gb: 24)), .medgemma15_4b)
        XCTAssertEqual(LlamaModel.medGemma(for: Self.mac(gb: 31)), .medgemma15_4b)
        XCTAssertEqual(LlamaModel.medGemma(for: Self.mac(gb: 32)), .medgemma15_4b)
        XCTAssertEqual(LlamaModel.medGemma(for: Self.mac(gb: 48)), .medgemma_27b)
        XCTAssertEqual(LlamaModel.medGemma(for: Self.mac(gb: 64)), .medgemma_27b)
    }

    func testExperimentalApertusRequiresSixteenGBOnAnyMac() {
        XCTAssertFalse(LlamaModel.apertus8b_meditronFO.isSupported(on: Self.mac(gb: 8)))
        XCTAssertTrue(LlamaModel.apertus8b_meditronFO.isSupported(on: Self.mac(gb: 16)))
        let intel = HardwareCapabilities(isAppleSilicon: false, physicalMemoryGB: 16, coreCount: 8, chipDescription: "Intel")
        XCTAssertTrue(LlamaModel.apertus8b_meditronFO.isSupported(on: intel))
        XCTAssertFalse(LlamaModel.medgemma_27b.isSupported(on: intel))
    }

    func testCuratedOfferAndPriorGeneralSelection() {
        XCTAssertEqual(
            LlamaModel.offered(for: Self.mac(gb: 16)),
            [.medgemma15_4b, .apertus8b_meditronFO]
        )
        XCTAssertEqual(
            LlamaModel.offered(for: Self.mac(gb: 32)),
            [.medgemma15_4b, .apertus8b_meditronFO, .medgemma_27b]
        )
        let intel = HardwareCapabilities(isAppleSilicon: false, physicalMemoryGB: 16, coreCount: 8, chipDescription: "Intel")
        XCTAssertEqual(LlamaModel.offered(for: intel), [.medgemma15_4b, .apertus8b_meditronFO])
        XCTAssertEqual(
            LlamaModel.offered(for: Self.mac(gb: 16), including: .llama31_8b),
            [.medgemma15_4b, .apertus8b_meditronFO, .llama31_8b]
        )
    }

    func testContextWindowsMatchTrainedLengths() {
        XCTAssertEqual(LlamaModel.llama31_8b.contextWindowTokens, 131_072)
        XCTAssertEqual(LlamaModel.gemma4_e2b.contextWindowTokens, 131_072)
        XCTAssertEqual(LlamaModel.medgemma15_4b.contextWindowTokens, 131_072)
        XCTAssertEqual(LlamaModel.medgemma_27b.contextWindowTokens, 131_072)
        XCTAssertEqual(LlamaModel.apertus8b_meditronFO.contextWindowTokens, 65_536)
    }

    func testFileNamesAreUnique() {
        let names = LlamaModel.allCases.map(\.fileName)
        XCTAssertEqual(Set(names).count, names.count)
    }
}

final class LlamaRuntimeTests: XCTestCase {
    func testRetiredDownloadsCanBeRemovedWithoutDeletingTheCurrentModel() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let retired = try XCTUnwrap(LlamaRuntime.retiredModelFiles.first)
        let oldURL = dir.appendingPathComponent(retired.fileName)
        let currentURL = dir.appendingPathComponent(LlamaModel.medgemma15_4b.fileName)
        try Data("old".utf8).write(to: oldURL)
        try Data("current".utf8).write(to: currentURL)
        XCTAssertEqual(LlamaRuntime.retiredDownloadedModels(in: dir).map(\.id), [retired.id])
        try LlamaRuntime.removeRetiredModel(retired, in: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentURL.path))
    }

    func testModelURLIsUnderModelsDirectoryWithFileName() {
        let url = LlamaRuntime.modelURL(for: .llama31_8b)
        XCTAssertEqual(url.lastPathComponent, LlamaModel.llama31_8b.fileName)
        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent == "Models")
    }

    func testUnusedDownloadedModelsAndRemoveModel() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let gemmaURL = dir.appendingPathComponent(LlamaModel.gemma4_e2b.fileName)
        try Data("weights".utf8).write(to: gemmaURL)
        try Data("resume".utf8).write(to: ModelFileInstaller.legacyResumeDataURL(for: gemmaURL))

        XCTAssertEqual(LlamaRuntime.unusedDownloadedModels(besides: .llama31_8b, in: dir), [.gemma4_e2b])
        XCTAssertTrue(LlamaRuntime.unusedDownloadedModels(besides: .gemma4_e2b, in: dir).isEmpty)

        try LlamaRuntime.removeModel(.gemma4_e2b, in: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gemmaURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelFileInstaller.legacyResumeDataURL(for: gemmaURL).path))
        XCTAssertTrue(LlamaRuntime.unusedDownloadedModels(besides: .llama31_8b, in: dir).isEmpty)
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
        XCTAssertThrowsError(try ModelFileInstaller.installVerified(
            from: download, to: dest, expectedSHA256: String(repeating: "0", count: 64)))
        XCTAssertEqual(try Data(contentsOf: dest), Data("good".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelFileInstaller.partialURL(for: dest).path))
    }

    func testMatchReplacesExistingAndLeavesNoPartialOrResumeFile() throws {
        let dir = try tmpDir()
        let dest = dir.appendingPathComponent("m.gguf")
        let download = dir.appendingPathComponent("tmp-download")
        try Data("old".utf8).write(to: dest)
        try Data("new".utf8).write(to: download)
        try Data("resume".utf8).write(to: ModelFileInstaller.legacyResumeDataURL(for: dest))
        let sha = try ModelDigest.sha256(ofFileAt: download)
        try ModelFileInstaller.installVerified(from: download, to: dest, expectedSHA256: sha)
        XCTAssertEqual(try Data(contentsOf: dest), Data("new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelFileInstaller.partialURL(for: dest).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelFileInstaller.legacyResumeDataURL(for: dest).path))
    }

    func testDiskSpaceCheckRefusesWhenVolumeIsTooFull() throws {
        let dir = try tmpDir()
        let asset = LlamaModel.gemma4_e2b.asset
        let neededMB = asset.approximateSizeMB + LlamaModelDownloader.diskSpaceHeadroomMB
        XCTAssertThrowsError(
            try LlamaModelDownloader.verifyAvailableDiskSpace(
                for: asset,
                at: dir,
                availableBytesProvider: { _ in Int64(neededMB - 1) * 1_048_576 }
            )
        ) { error in
            XCTAssertEqual(error as? ModelDownloadError, .insufficientDiskSpace(neededMB: neededMB))
        }

        XCTAssertNoThrow(
            try LlamaModelDownloader.verifyAvailableDiskSpace(
                for: asset,
                at: dir,
                availableBytesProvider: { _ in Int64(neededMB) * 1_048_576 }
            )
        )
    }

    func testStatusLabelShowsVerificationAt100Percent() {
        XCTAssertEqual(LlamaModelDownloader.statusLabel(forProgress: 0.42), "Downloading model… (42%)")
        XCTAssertEqual(LlamaModelDownloader.statusLabel(forProgress: 1.0), "Verifying downloaded model…")
    }

    func testDiskSpaceCheckAllowsUnknownVolumeCapacityAndFormatsError() throws {
        let dir = try tmpDir()
        let asset = LlamaModel.llama31_8b.asset
        XCTAssertNoThrow(
            try LlamaModelDownloader.verifyAvailableDiskSpace(
                for: asset,
                at: dir,
                availableBytesProvider: { _ in nil }
            )
        )
        let err = ModelDownloadError.insufficientDiskSpace(neededMB: 3353)
        XCTAssertEqual(
            err.errorDescription,
            "Not enough free disk space to download the model (at least 3.3 GB required)."
        )
    }
}
