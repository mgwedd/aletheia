import XCTest

extension Copy {
    static let medLlama2Option = "MedLlama 2 7B — medical, 8 GB+ Macs"
    static let medGemma4BOption = "MedGemma 4B (Instruct) — medical, 8 GB+ Macs"
    static let llama2License = "Llama 2 Community License"
    static let healthAIFoundationsTerms = "Health AI Developer Foundations Terms"
}

/// Settings > AI and models on screen.
struct AIAndModelsPaneOnScreen {
    let driver: AppDriver

    var modelPicker: XCUIElement {
        let identified = driver.app.popUpButtons["built-in-model-picker"]
        if driver.exists(identified) { return identified }
        let all = driver.app.popUpButtons.allElementsBoundByIndex
        return all.count > 1 ? all[1] : all[0]
    }

    var builtInModelHeader: XCUIElement {
        driver.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Built-in model", "Built-in model"))
            .firstMatch
    }

    func licenseLink(_ title: String) -> XCUIElement {
        driver.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", title, title))
            .firstMatch
    }
}

extension Given {
    func licensedAppWithMemory(gb: Int) {
        app.seed {
            $0.license = "test"
            $0.fileVault = "on"
            $0.memoryGB = gb
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

    func chooseBuiltInModel(_ option: String, on pane: AIAndModelsPaneOnScreen) {
        XCTAssertTrue(app.exists(pane.modelPicker), "no built-in model picker")
        pane.modelPicker.click()
        let item = app.app.menuItems[option].firstMatch
        if app.exists(item) {
            item.click()
        } else {
            app.tap(option)
        }
    }
}

extension Then where Subject == AIAndModelsPaneOnScreen {
    func showsLicense(_ name: String) {
        expect(subject.driver.exists(subject.licenseLink(name)), "no \(name) link on AI and models")
    }
}
