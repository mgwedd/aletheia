import XCTest

extension Copy {
    static let medGemma4BID = "medgemma-1.5-4b-it-q4_k_m"
    static let medGemma27BID = "medgemma-27b-text-it-q4_k_m"
    static let apertus8BID = "apertus-8b-meditronfo-q4_k_m"
    static let llama8BID = "meta-llama-3.1-8b-instruct-q4_0"
    static let llama8BOption = "Llama 3.1 8B (Instruct) — previous selection"
    static let medGemma4BOption = "MedGemma 1.5 4B — default for supported Macs"
    static let medGemma27BOption = "MedGemma 27B text — higher quality, 32 GB+ Apple silicon"
    static let apertus8BOption = "Apertus 8B MeditronFO — Experimental, 16 GB+ Macs"
    static let healthAIFoundationsTerms = "Health AI Developer Foundations Terms"
}

/// Settings > AI and models on screen.
struct AIAndModelsPaneOnScreen {
    let driver: AppDriver

    var modelPicker: XCUIElement {
        let identified = driver.app.descendants(matching: .any)["built-in-model-picker"]
        let popUp = identified.popUpButtons.firstMatch
        if popUp.exists { return popUp }
        if identified.exists { return identified }
        let all = driver.app.popUpButtons.allElementsBoundByIndex
        return all.count > 1 ? all[1] : all[0]
    }

    var builtInModelHeader: XCUIElement {
        driver.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@ OR title CONTAINS %@", "Built-in model", "Built-in model", "Built-in model"))
            .firstMatch
    }

    func licenseLink(_ title: String) -> XCUIElement {
        let byId = driver.app.descendants(matching: .any)["model-license-link"]
        if byId.exists { return byId }
        return driver.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@ OR title CONTAINS %@", title, title, title))
            .firstMatch
    }
}

extension Given {
    func licensedAppWithMemory(gb: Int, model: String) {
        app.seed {
            $0.license = "test"
            $0.fileVault = "on"
            $0.memoryGB = gb
            $0.llamaModel = model
        }
    }
}

extension Given {
    /// Updated from a version that defaulted to `model`, downloaded and never chosen.
    func updatedAppWithMemory(gb: Int, downloaded model: String) {
        app.seed {
            $0.license = "test"
            $0.fileVault = "on"
            $0.memoryGB = gb
            $0.downloadedModels = [model]
        }
    }
}

extension When {
    func openAIAndModelsSettings() -> AIAndModelsPaneOnScreen {
        app.ensureLaunched()
        app.app.typeKey(",", modifierFlags: .command)
        let row = app.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", "AI and models", "AI and models"))
            .firstMatch
        XCTAssertTrue(app.exists(row), "no AI and models row in Settings sidebar")
        row.click()
        let pane = AIAndModelsPaneOnScreen(driver: app)
        XCTAssertTrue(app.exists(pane.builtInModelHeader), "no Built-in model header on AI and models")
        XCTAssertTrue(app.exists(pane.modelPicker), "no built-in model picker on AI and models")
        return pane
    }
}

extension Then where Subject == AIAndModelsPaneOnScreen {
    func showsLicense(_ name: String) {
        expect(subject.driver.exists(subject.licenseLink(name)), "no \(name) link on AI and models")
    }

    func showsSelectedModel(_ name: String) {
        let picker = subject.modelPicker
        expect(subject.driver.exists(picker), "no model picker")
        let val = picker.value as? String ?? picker.label
        expect(val.contains(name) || subject.driver.exists(subject.driver.app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@ OR title CONTAINS %@", name, name, name)).firstMatch), "expected model \(name) to be selected, got \(val)")
    }
}
