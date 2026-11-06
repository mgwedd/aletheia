import XCTest

extension Copy {
    static let summaryReady = "Summary ready"
    static let summarizeAfterRecording = "Write the summary after recording"
    static let summarySuggestionTitle = "After recording, write the summary automatically"
}

/// What the app holds once a session has been imported and transcribed.
struct AutoSummaryOnScreen {
    let driver: AppDriver

    static func hasNote(_ probe: ProbeSnapshot) -> Bool {
        probe.files.contains { name in
            let file = name.split(separator: "/").last.map(String.init) ?? name
            return file.hasPrefix("note.") && file.hasSuffix(".txt") && file.split(separator: ".").count == 3
        }
    }

    static func summaryReady(_ probe: ProbeSnapshot) -> [String] {
        probe.notifications.filter { $0.hasPrefix(Copy.summaryReady + ":") }
    }

    static func hasTranscript(_ probe: ProbeSnapshot) -> Bool {
        probe.files.contains { $0.hasSuffix("transcript.txt") }
    }
}

extension Given {
    /// Jane Doe's session, ready for a recording to be imported, with
    /// "Write the summary after recording" set as given.
    func aSessionToRecord(summarizeAfterRecording: Bool) {
        app.seed {
            $0.license = "test"
            $0.fileVault = "on"
            $0.importFile = "clip"
            $0.summarizesAfterRecording = summarizeAfterRecording
            $0.heardTracks = [
                .init(speaker: "You", from: 0, to: 3, text: "How has your week been?"),
                .init(speaker: "Client", from: 4, to: 9, text: "Better. I slept most nights and walked twice."),
            ]
            $0.aiReplies = ["Client reports a better week: sleeping most nights and walking twice."]
            $0.patients = [.init(name: "Jane Doe", sessions: 1, recordingConsent: true)]
            $0.open = "Jane Doe"
        }
    }
}

extension When {
    /// Imports a recording and waits for its transcript.
    func importARecordingAndLetItTranscribe() -> AutoSummaryOnScreen {
        importARecording()
        app.waitForProbe(timeout: 60) { AutoSummaryOnScreen.hasTranscript($0) }
        return AutoSummaryOnScreen(driver: app)
    }
}

extension Then where Subject == AutoSummaryOnScreen {
    /// The summary is saved and "Summary ready" arrives, naming no one.
    func writesTheSummaryAndAnnouncesItWithoutNaming(_ name: String) {
        let probe = subject.driver.waitForProbe(timeout: 60) {
            AutoSummaryOnScreen.hasNote($0) && !AutoSummaryOnScreen.summaryReady($0).isEmpty
        }
        expect(AutoSummaryOnScreen.hasNote(probe), "no summary was written: \(probe.files)")
        let ready = AutoSummaryOnScreen.summaryReady(probe)
        expect(ready.count == 1, "expected one \"\(Copy.summaryReady)\" notification, got \(probe.notifications)")
        let initials = name.split(separator: " ").compactMap(\.first).map(String.init)
        for shown in ready {
            for part in name.split(separator: " ") {
                expect(!shown.contains(part), "the notification names the patient: \(shown)")
            }
            expect(!shown.contains(initials.joined()) && !shown.contains(initials.joined(separator: ".") + "."),
                   "the notification shows the patient's initials: \(shown)")
        }
    }

    /// Nothing comes in the time a summary takes when the setting is on.
    func writesNoSummary() {
        let driver = subject.driver
        let appeared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let probe = driver.probe
            return AutoSummaryOnScreen.hasNote(probe) || !AutoSummaryOnScreen.summaryReady(probe).isEmpty
        }, object: nil)
        let outcome = XCTWaiter().wait(for: [appeared], timeout: 15)
        let probe = driver.probe
        expect(outcome == .timedOut, "a summary was written or announced: \(probe.files), \(probe.notifications)")
    }
}

// MARK: - The settings switch and the setup suggestion

extension Given {
    /// A fresh install on an Apple silicon Mac.
    func freshInstallOnAnAppleSiliconMac() {
        app.seed {
            $0.license = "test"
            $0.fileVault = "on"
            $0.intel = false
            $0.memoryGB = 16
        }
    }

    /// The setup sheet is up (terms accepted, no folder yet) on an Intel or Apple silicon Mac.
    func setupOnAnIntelMac(_ intel: Bool) {
        app.seed {
            $0.noDataFolder = true
            $0.intel = intel
        }
    }
}

/// Settings > General on screen.
struct GeneralSettingsOnScreen {
    let driver: AppDriver

    var summarizeSwitch: XCUIElement {
        driver.app.descendants(matching: .any)
            .matching(NSPredicate(format: "(elementType == %d OR elementType == %d) AND (label == %@ OR title == %@)",
                                  XCUIElement.ElementType.switch.rawValue, XCUIElement.ElementType.checkBox.rawValue,
                                  Copy.summarizeAfterRecording, Copy.summarizeAfterRecording))
            .firstMatch
    }
}

extension When {
    func openGeneralSettings() -> GeneralSettingsOnScreen {
        app.ensureLaunched()
        app.app.typeKey(",", modifierFlags: .command)
        let row = app.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", "General", "General"))
            .firstMatch
        XCTAssertTrue(app.exists(row), "no General row in Settings sidebar")
        row.click()
        return GeneralSettingsOnScreen(driver: app)
    }
}

extension Then where Subject == GeneralSettingsOnScreen {
    func summarizeAfterRecordingIsOff() {
        let toggle = subject.summarizeSwitch
        expect(subject.driver.exists(toggle), "no \(Copy.summarizeAfterRecording) switch in General")
        expect(isOn(toggle) == false, "\(Copy.summarizeAfterRecording) is on: \(String(describing: toggle.value))")
    }
}

/// A switch's state as XCUI reports it; nil when it reports none.
private func isOn(_ toggle: XCUIElement) -> Bool? {
    switch toggle.value {
    case let number as NSNumber: return number.boolValue
    case let text as String: return text == "1"
    default: return nil
    }
}

extension Then where Subject == SetupSheetOnScreen {
    var summarySuggestion: XCUIElement { subject.driver.element(id: "setup-auto-summary") }

    func suggestsWritingTheSummaryAfterRecording() {
        let toggle = summarySuggestion
        expect(subject.driver.exists(toggle), "no suggestion to write the summary after recording")
        let words = toggle.label + " " + (subject.text(Copy.summarySuggestionTitle).exists ? Copy.summarySuggestionTitle : "")
        expect(words.contains(Copy.summarySuggestionTitle), "the suggestion does not read \"\(Copy.summarySuggestionTitle)\": \(toggle.label)")
        expect(isOn(toggle) == false, "the suggestion is already on: \(String(describing: toggle.value))")
    }

    func doesNotSuggestWritingTheSummaryAfterRecording() {
        expect(subject.driver.gone(summarySuggestion), "the setup sheet suggests writing the summary after recording")
    }
}
