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

    /// AppSettings loads with `LlamaModel(rawValue:) ?? .recommended`, so a
    /// persisted raw value from a retired model must not resolve (and not crash).
    func testRetiredRawValuesFallBackToRecommended() {
        for legacy in ["llama-3.2-1b-instruct-q4_k_m", "llama-3.2-3b-instruct-q4_k_m"] {
            XCTAssertNil(LlamaModel(rawValue: legacy))
            XCTAssertEqual(LlamaModel(rawValue: legacy) ?? .recommended, .llama31_8b)
        }
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

    func testUnavailableWhenModelFileMissing() {
        // Whether or not the runtime is linked, a model with no file on disk is
        // not "available" — so the resolver falls back rather than trying to
        // load a missing model.
        XCTAssertFalse(LlamaRuntime.isAvailable(model: .gemma4_e2b))
    }
}
