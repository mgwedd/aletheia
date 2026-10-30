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
        [HelpTips.myNotes, HelpTips.compact]
            + settingsTips
    }

    private var settingsTips: [HelpTip] {
        [HelpTips.autoTranscribe, HelpTips.aiInstructions, HelpTips.defaultNoteFormat,
         HelpTips.includeComments, HelpTips.summariesOnBattery]
    }

    func testIdsAreFixed() {
        // Read state is stored under these ids; changing one re-shows the tip.
        XCTAssertEqual(HelpTips.myNotes.id, "notes.mine")
        XCTAssertEqual(HelpTips.compact.id, "chat.compact")
        XCTAssertEqual(settingsTips.map(\.id), [
            "settings.autoTranscribe", "settings.aiInstructions", "settings.defaultNoteFormat",
            "settings.includeComments", "settings.summariesOnBattery",
        ])
    }

    func testDistinctTipsHaveDistinctIds() {
        let ids = ([HelpTips.myNotes, HelpTips.compact] + settingsTips).map(\.id)
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
            // The Ask-all field's scope tip and its "Read: …" coverage line were noise.
            "What answers come from",
            "coverageNotice",
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

    /// Compaction isn't a word therapists use; the tip says, in one sentence, what it does and why.
    func testCompactTipExplainsWhatAndWhy() throws {
        let text = HelpTips.compact.text
        XCTAssertTrue(text.contains("Compressing the conversation"))
        XCTAssertTrue(text.contains("longer conversations"))
        XCTAssertEqual(text.filter { ".!?".contains($0) }.count, 1, "one sentence")
        let pane = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/App/Views/ChatPaneView.swift"), encoding: .utf8)
        XCTAssertTrue(pane.contains(".hoverTip(HelpTips.compact"))
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
                     "Aletheia locks after 15 minutes of inactivity by default",
                     "current medications are provided to the assistant",
                     "On by default, which keeps your data folder out of Time Machine and iCloud",
                     "FileVault encrypts everything on this Mac at rest"] {
            XCTAssertTrue(settings.contains(kept), kept)
        }
    }

    /// The AI instructions tip covers the whole section, not only the editor.
    func testAIInstructionsTipIsOnTheSection() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/App/Views/SettingsView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(settings.range(of: "private var instructionsCard: some View {"))
        let end = try XCTUnwrap(settings.range(of: "private var riskPhrasesCard", range: start.upperBound..<settings.endIndex))
        let card = settings[start.upperBound..<end.lowerBound]
        XCTAssertFalse(card.contains("minHeight: 140)\n                .hoverTip"), "tip is on the editor")
        XCTAssertTrue(card.contains("        }\n        // On the section"), "tip should follow the card's closing brace")
        XCTAssertTrue(card.contains(".hoverTip(HelpTips.aiInstructions)"))
    }

    /// Every tip opens just below the pointer, clear of the cursor, whatever
    /// the control's size.
    func testTipsOpenJustBelowThePointer() {
        let anchor = HoverTipPlacement.anchor(below: CGPoint(x: 120, y: 40))
        XCTAssertEqual(anchor.minX, 120)
        XCTAssertEqual(anchor.minY, 40 + HoverTipPlacement.gap)
        XCTAssertGreaterThanOrEqual(HoverTipPlacement.gap, 16, "below the arrow cursor")
    }

    func testAShowingTipClosesWhenThePointerLeaves() {
        var intent = HoverIntent()
        let now = ContinuousClock.now
        let deadline = intent.enter(at: now)
        XCTAssertFalse(intent.wake(deadline, at: now + .seconds(1)))
        XCTAssertTrue(intent.wake(deadline, at: now + .seconds(2)))
        intent.exit()
        XCTAssertFalse(intent.isShowing)
        XCTAssertFalse(intent.wake(deadline, at: now + .seconds(3)), "an old deadline can't reopen it")
    }
}
