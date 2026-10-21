import XCTest
import TipKit
@testable import Aletheia

final class HoverIntentTests: XCTestCase {
    private let start = ContinuousClock.now

    func testDefaultDelayIsTwoSeconds() {
        XCTAssertEqual(HoverIntent.defaultDelay, .seconds(2))
        XCTAssertEqual(HoverIntent().delay, .seconds(2))
    }

    func testFiresOnlyOnceThePointerHasRestedForTheDelay() {
        var intent = HoverIntent()
        let deadline = intent.enter(at: start)
        XCTAssertEqual(deadline.instant, start + .seconds(2))
        XCTAssertFalse(intent.isDue(deadline, at: start))
        XCTAssertFalse(intent.isDue(deadline, at: start + .milliseconds(1_999)))
        XCTAssertTrue(intent.isDue(deadline, at: start + .seconds(2)))
        XCTAssertTrue(intent.isDue(deadline, at: start + .seconds(5)))
    }

    func testLeavingCancelsThePendingTip() {
        var intent = HoverIntent()
        let deadline = intent.enter(at: start)
        intent.exit()
        XCTAssertFalse(intent.isDue(deadline, at: start + .seconds(3)))
    }

    func testComingBackRestartsTheWait() {
        var intent = HoverIntent()
        let first = intent.enter(at: start)
        intent.exit()
        let second = intent.enter(at: start + .seconds(1))
        // The first visit's timer is void even once its time has passed…
        XCTAssertFalse(intent.isDue(first, at: start + .seconds(2)))
        // …and the second needs its own full two seconds.
        XCTAssertFalse(intent.isDue(second, at: start + .milliseconds(2_999)))
        XCTAssertTrue(intent.isDue(second, at: start + .seconds(3)))
    }

    func testReEnteringWithoutAnExitAlsoVoidsTheEarlierDeadline() {
        var intent = HoverIntent()
        let first = intent.enter(at: start)
        let second = intent.enter(at: start + .milliseconds(500))
        XCTAssertFalse(intent.isDue(first, at: start + .seconds(10)))
        XCTAssertTrue(intent.isDue(second, at: start + .milliseconds(2_500)))
    }

    func testCustomDelay() {
        var intent = HoverIntent(delay: .milliseconds(300))
        let deadline = intent.enter(at: start)
        XCTAssertFalse(intent.isDue(deadline, at: start + .milliseconds(299)))
        XCTAssertTrue(intent.isDue(deadline, at: start + .milliseconds(300)))
    }
}

final class HelpTipsTests: XCTestCase {
    private var allTips: [HelpTip] {
        [HelpTips.myNotes, HelpTips.patientChatScope]
            + settingsTips
    }

    private var settingsTips: [HelpTip] {
        [HelpTips.autoTranscribe, HelpTips.aiInstructions, HelpTips.defaultNoteFormat,
         HelpTips.includeComments, HelpTips.summariesOnBattery]
    }

    func testIdsAreFixed() {
        // Read state is stored under these ids; changing one re-shows the tip.
        XCTAssertEqual(HelpTips.myNotes.id, "notes.mine")
        XCTAssertEqual(HelpTips.patientChatScope.id, "chat.patient.scope")
        XCTAssertEqual(settingsTips.map(\.id), [
            "settings.autoTranscribe", "settings.aiInstructions", "settings.defaultNoteFormat",
            "settings.includeComments", "settings.summariesOnBattery",
        ])
    }

    func testDistinctTipsHaveDistinctIds() {
        let ids = ([HelpTips.myNotes, HelpTips.patientChatScope] + settingsTips).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testEveryTipHasAHeadingAndText() {
        for tip in allTips {
            XCTAssertFalse(tip.heading.isEmpty, tip.id)
            XCTAssertFalse(tip.text.isEmpty, tip.id)
            XCTAssertEqual(tip.title, Text(tip.heading), tip.id)
            XCTAssertEqual(tip.message, Text(tip.text), tip.id)
        }
    }

    func testRemovedCopyDoesNotReturnToTheSources() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let banned = [
            "Answers come from this session's transcript",
            "AI-generated. Read alongside",
            "centers what happened in the room",
            "most widely accepted progress-note format",
            "# Aletheia —",
            "var blurb: String",
        ]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for phrase in banned where text.contains(phrase) {
                // Effort and verbosity levels keep their own blurbs; only the note format's is gone.
                if phrase == "var blurb: String" && !url.lastPathComponent.hasPrefix("ProgressNoteFormat") { continue }
                offenders.append("\(url.lastPathComponent): \(phrase)")
            }
        }
        XCTAssertEqual(offenders, [])
    }

    func testExportFormatRowsHaveNoFocusRing() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/App/Views/ExportButton.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".focusEffectDisabled()"))
    }

    func testPatientChatTipKeepsTheScopeTheContextBuilderUses() {
        XCTAssertEqual(HelpTips.patientChatScope.text, PatientChatView.scopeNote)
    }

    func testTipsHaveNoRulesOrActions() {
        // Hover is the only trigger; a rule or action would change when it shows.
        for tip in allTips {
            XCTAssertTrue(tip.rules.isEmpty, tip.id)
            XCTAssertTrue(tip.actions.isEmpty, tip.id)
        }
    }

    func testStoreStaysOnThisMac() {
        XCTAssertEqual(HelpTipsStore.datastoreLocation, .applicationDefault)
        XCTAssertEqual(HelpTipsStore.displayFrequency, .immediate)
        let expected = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)) ? 3 : 2
        XCTAssertEqual(HelpTipsStore.options.count, expected)
    }

    /// Settings asides moved into tips; the lines needed to act safely stay
    /// in the layout.
    func testSettingsKeepSafetyCopyInlineAndMoveAsidesToTips() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/App/Views/SettingsView.swift"), encoding: .utf8)
        for tip in settingsTips {
            XCTAssertFalse(settings.contains(tip.text), "\(tip.id) is still inline")
            XCTAssertTrue(settings.contains("HelpTips.\(tip.id.dropFirst("settings.".count))"), tip.id)
        }
        for kept in ["Require Touch ID or your Mac password to open.",
                     "Aletheia already locks when your Mac locks or sleeps",
                     "current medications are provided to the assistant",
                     "Off by default, so Time Machine includes your data folder",
                     "FileVault encrypts everything on this Mac at rest"] {
            XCTAssertTrue(settings.contains(kept), kept)
        }
    }
}
