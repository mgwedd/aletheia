import XCTest

/// Built-in model choices in Settings > AI and models.
final class SettingsUITests: AcceptanceCase {
    func test_SETTINGS_15() {
        given.licensedAppWithMemory(gb: 16, model: Copy.medGemma4BID)
        let paneGemma4B = when.openAIAndModelsSettings()
        then(paneGemma4B).showsSelectedModel(Copy.medGemma4BOption)
        then(paneGemma4B).showsLicense(Copy.healthAIFoundationsTerms)

        given.licensedAppWithMemory(gb: 16, model: Copy.apertus8BID)
        let paneApertus = when.openAIAndModelsSettings()
        then(paneApertus).showsSelectedModel(Copy.apertus8BOption)
        then(paneApertus).showsLicense("Apache License 2.0")

        given.licensedAppWithMemory(gb: 32, model: Copy.medGemma27BID)
        let paneGemma27B = when.openAIAndModelsSettings()
        then(paneGemma27B).showsSelectedModel(Copy.medGemma27BOption)
        then(paneGemma27B).showsLicense(Copy.healthAIFoundationsTerms)
    }

    func test_SETTINGS_16_anUpdateKeepsTheDownloadedModel() {
        given.updatedAppWithMemory(gb: 16, downloaded: Copy.llama8BID)
        let pane = when.openAIAndModelsSettings()
        then(pane).showsSelectedModel(Copy.llama8BOption)
    }

    func test_SETTINGS_17() {
        given.licensedAppWhoseDownloadsFail()
        let pane = when.openAIAndModelsSettings()
        let alert = when.startADownload(on: pane)
        then(alert).offers(["Try Again", "Report a Bug"])
        let again = when.tryAgain(alert)
        then(again).offers(["Try Again", "Report a Bug"])
    }
}
