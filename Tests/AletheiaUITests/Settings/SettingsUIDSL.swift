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

    var modelPicker: XCUIElement { driver.app.popUpButtons["Model"].firstMatch }

    func licenseLink(_ title: String) -> XCUIElement {
        driver.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", title, title))
            .firstMatch
    }
}

extension Given {
    func macHasMemory(gb: Int) {
        app.seed { $0.memoryGB = gb }
    }
}

extension When {
    func openAIAndModelsSettings() -> AIAndModelsPaneOnScreen {
        app.ensureLaunched()
        app.app.typeKey(",", modifierFlags: .command)
        app.tap("AI and models")
        let pane = AIAndModelsPaneOnScreen(driver: app)
        XCTAssertTrue(app.exists(pane.modelPicker), "no built-in model picker on AI and models")
        return pane
    }

    func chooseBuiltInModel(_ option: String, on pane: AIAndModelsPaneOnScreen) {
        XCTAssertTrue(app.exists(pane.modelPicker), "no built-in model picker")
        pane.modelPicker.click()
        let item = app.app.menuItems[option].firstMatch
        XCTAssertTrue(app.exists(item), "no \(option) in the built-in model menu")
        item.click()
    }
}

extension Then where Subject == AIAndModelsPaneOnScreen {
    func showsLicense(_ name: String) {
        expect(subject.driver.exists(subject.licenseLink(name)), "no \(name) link on AI and models")
    }
}
