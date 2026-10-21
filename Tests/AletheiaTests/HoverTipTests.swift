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
        [HelpTips.myNotes, HelpTips.sessionChatScope, HelpTips.patientChatScope]
            + ProgressNoteFormat.allCases.map(HelpTips.noteFormat)
    }

    func testIdsAreFixed() {
        // Read state is stored under these ids; changing one re-shows the tip.
        XCTAssertEqual(HelpTips.myNotes.id, "notes.mine")
        XCTAssertEqual(HelpTips.sessionChatScope.id, "chat.session.scope")
        XCTAssertEqual(HelpTips.patientChatScope.id, "chat.patient.scope")
        for format in ProgressNoteFormat.allCases {
            XCTAssertEqual(HelpTips.noteFormat(format).id, "notes.format")
        }
    }

    func testDistinctTipsHaveDistinctIds() {
        let ids = [HelpTips.noteFormat(.soap), HelpTips.myNotes,
                   HelpTips.sessionChatScope, HelpTips.patientChatScope].map(\.id)
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

    func testNoteFormatTipFollowsTheSelectedFormat() {
        for format in ProgressNoteFormat.allCases {
            let tip = HelpTips.noteFormat(format)
            XCTAssertEqual(tip.heading, format.displayName)
            XCTAssertEqual(tip.text, format.blurb)
        }
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
}
