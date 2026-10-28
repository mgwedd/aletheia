import XCTest

/// Built-in model choices in Settings > AI and models.
final class SettingsUITests: AcceptanceCase {
    func test_SETTINGS_15() {
        given.macHasMemory(gb: 16)
        let pane = when.openAIAndModelsSettings()

        when.chooseBuiltInModel(Copy.medLlama2Option, on: pane)
        then(pane).showsLicense(Copy.llama2License)

        when.chooseBuiltInModel(Copy.medGemma4BOption, on: pane)
        then(pane).showsLicense(Copy.healthAIFoundationsTerms)
    }
}
