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

    func testFileNamesAreUnique() {
        let names = LlamaModel.allCases.map(\.fileName)
        XCTAssertEqual(Set(names).count, names.count)
    }
}

final class LlamaRuntimeTests: XCTestCase {
    func testModelURLIsUnderModelsDirectoryWithFileName() {
        let url = LlamaRuntime.modelURL(for: .llama32_3b)
        XCTAssertEqual(url.lastPathComponent, LlamaModel.llama32_3b.fileName)
        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent == "Models")
    }

    func testUnavailableWhenModelFileMissing() {
        // Whether or not the runtime is linked, a model with no file on disk is
        // not "available" — so the resolver falls back rather than trying to
        // load a missing model.
        XCTAssertFalse(LlamaRuntime.isAvailable(model: .llama32_1b))
    }
}
