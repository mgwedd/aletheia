import XCTest
@testable import Aletheia

/// Guards the state→(symbol, label, color) mapping the menu bar's engine
/// status line renders. `EngineStatusPresentation.present` is pure — no
/// network, no environment — so every branch is checked directly here rather
/// than through the view.
final class EngineStatusTests: XCTestCase {
    func testLoadingIsGrayWithNeutralSymbol() {
        let presentation = EngineStatusPresentation.present(.loading)
        XCTAssertEqual(presentation.tint, .gray)
        XCTAssertEqual(presentation.symbolName, "circle.dotted")
    }

    func testReachableWithModelIsGreenAndNamesEngineAndModel() {
        let presentation = EngineStatusPresentation.present(
            .reachable(engineName: "Built-in engine", modelName: "Qwen")
        )
        XCTAssertEqual(presentation.tint, .green)
        XCTAssertEqual(presentation.symbolName, "checkmark.circle.fill")
        XCTAssertTrue(presentation.label.contains("Built-in engine"))
        XCTAssertTrue(presentation.label.contains("Qwen"))
    }

    func testReachableWithoutModelIsYellowAndSaysNotDownloaded() {
        let presentation = EngineStatusPresentation.present(
            .reachableNoModel(engineName: "Built-in engine", modelName: "Qwen")
        )
        XCTAssertEqual(presentation.tint, .yellow)
        XCTAssertEqual(presentation.symbolName, "exclamationmark.triangle.fill")
        XCTAssertTrue(presentation.label.contains("Qwen"))
        XCTAssertTrue(presentation.label.lowercased().contains("not downloaded"))
    }

    func testUnreachableIsRedAndNamesEngine() {
        let presentation = EngineStatusPresentation.present(.unreachable(engineName: "Built-in engine"))
        XCTAssertEqual(presentation.tint, .red)
        XCTAssertEqual(presentation.symbolName, "xmark.circle.fill")
        XCTAssertTrue(presentation.label.contains("Built-in engine"))
    }

    // MARK: Engine/model naming per backend

    func testEngineNameNamesBuiltInEngineForLocalLlamaAndAutomatic() {
        XCTAssertEqual(EngineStatusProbe.engineName(for: .localLlama), "Built-in engine")
        XCTAssertEqual(EngineStatusProbe.engineName(for: .automatic), "Built-in engine")
    }

    func testEngineNameNamesAppleIntelligence() {
        XCTAssertEqual(EngineStatusProbe.engineName(for: .appleIntelligence), "Apple Intelligence")
    }
}
