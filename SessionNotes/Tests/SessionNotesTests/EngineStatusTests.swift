import XCTest
@testable import SessionNotes

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
            .reachable(engineName: "Ollama", modelName: "llama3.1:8b")
        )
        XCTAssertEqual(presentation.tint, .green)
        XCTAssertEqual(presentation.symbolName, "checkmark.circle.fill")
        XCTAssertTrue(presentation.label.contains("Ollama"))
        XCTAssertTrue(presentation.label.contains("llama3.1:8b"))
    }

    func testReachableWithoutModelIsYellowAndSaysNotDownloaded() {
        let presentation = EngineStatusPresentation.present(
            .reachableNoModel(engineName: "Ollama", modelName: "llama3.1:8b")
        )
        XCTAssertEqual(presentation.tint, .yellow)
        XCTAssertEqual(presentation.symbolName, "exclamationmark.triangle.fill")
        XCTAssertTrue(presentation.label.contains("llama3.1:8b"))
        XCTAssertTrue(presentation.label.lowercased().contains("not downloaded"))
    }

    func testUnreachableIsRedAndNamesEngine() {
        let presentation = EngineStatusPresentation.present(.unreachable(engineName: "Ollama"))
        XCTAssertEqual(presentation.tint, .red)
        XCTAssertEqual(presentation.symbolName, "xmark.circle.fill")
        XCTAssertTrue(presentation.label.contains("Ollama"))
    }

    // MARK: Engine/model naming per backend

    func testEngineNameNamesOllamaForOllamaAndAutomatic() {
        XCTAssertEqual(EngineStatusProbe.engineName(for: .ollama), "Ollama")
        XCTAssertEqual(EngineStatusProbe.engineName(for: .automatic), "Ollama")
    }

    func testEngineNameNamesBuiltInEngineForLocalLlama() {
        XCTAssertEqual(EngineStatusProbe.engineName(for: .localLlama), "Built-in engine")
    }

    func testEngineNameNamesAppleIntelligence() {
        XCTAssertEqual(EngineStatusProbe.engineName(for: .appleIntelligence), "Apple Intelligence")
    }
}
