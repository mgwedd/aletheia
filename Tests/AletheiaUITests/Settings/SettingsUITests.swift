import XCTest

/// Built-in model choices in Settings > AI and models.
final class SettingsUITests: AcceptanceCase {
    func test_SETTINGS_15() {
        given.licensedAppWithMemory(gb: 16, model: Copy.medGemma4BID)
        let paneGemma4B = when.openAIAndModelsSettings()
        then(paneGemma4B).showsSelectedModel(Copy.medGemma4BOption)
        then(paneGemma4B).showsLicense(Copy.healthAIFoundationsTerms)

        given.licensedAppWithMemory(gb: 32, model: Copy.medGemma27BID)
        let paneGemma27B = when.openAIAndModelsSettings()
        then(paneGemma27B).showsSelectedModel(Copy.medGemma27BOption)
        then(paneGemma27B).showsLicense(Copy.healthAIFoundationsTerms)
    }
}
