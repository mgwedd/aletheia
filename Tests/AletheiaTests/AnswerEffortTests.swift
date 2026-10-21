import XCTest
@testable import Aletheia

/// The effort levels do what their descriptions say: each description is
/// checked against the values the code runs on, for every feature.
@MainActor
final class AnswerEffortTests: XCTestCase {
    func testEveryDescriptionStatesWhatTheLevelDoes() {
        for feature in EffortFeature.allCases {
            for effort in AnswerEffort.allCases {
                let blurb = effort.blurb(for: feature)
                let name = "\(effort.displayName) \(feature)"
                // Material that fits is read whole at every level.
                XCTAssertTrue(blurb.contains("read whole"), name)

                // Lookups: named with their count and rounds where the code makes them, never elsewhere.
                if feature != .note && effort.maxToolCalls > 0 {
                    let rounds = effort.maxRefinementRounds
                    XCTAssertTrue(
                        blurb.contains("up to \(effort.maxToolCalls) lookups in \(rounds) round\(rounds == 1 ? "" : "s")"),
                        name + ": " + blurb)
                } else {
                    XCTAssertFalse(blurb.contains("lookup"), name + ": " + blurb)
                }

                // The check: claimed exactly where it runs.
                XCTAssertEqual(blurb.contains("checks"), effort.checksDraft(for: feature), name + ": " + blurb)

                // Fast's cap is the number the code uses.
                if let cap = effort.materialCap(for: feature) {
                    XCTAssertTrue(blurb.contains("about \(AnswerEffort.grouped(cap)) characters"), name + ": " + blurb)
                }
                XCTAssertEqual(blurb.hasPrefix("Quickest"), effort == .fast, name)
                XCTAssertEqual(blurb.hasPrefix("Slowest"), effort == .focus, name)
            }
        }
    }

    func testOnlyLongNotesAtFocusAreChecked() {
        for feature in EffortFeature.allCases {
            for effort in AnswerEffort.allCases {
                XCTAssertEqual(effort.checksDraft(for: feature), effort == .focus && feature == .note)
            }
        }
        XCTAssertNil(AnswerEffort.normal.materialCap(for: .note))
        XCTAssertNil(AnswerEffort.focus.materialCap(for: .patientChat))
    }

    /// Focus asks for more lookups than Normal, so it keeps more room: each of
    /// them gets an even share instead of the first few using it all.
    func testEveryLookupHasRoomAndFocusKeepsMore() {
        for total in [6_000, 20_000, 36_000, 80_000, 168_000] {
            XCTAssertGreaterThan(AnswerEffort.focus.lookupReserve(total: total), AnswerEffort.normal.lookupReserve(total: total) - 1, "\(total)")
            XCTAssertEqual(AnswerEffort.fast.lookupReserve(total: total), 0)
            for effort in [AnswerEffort.normal, .focus] {
                let reserve = effort.lookupReserve(total: total)
                XCTAssertLessThanOrEqual(reserve, total / 3, "never more than a third of the room")
                let size = effort.lookupCharacters(reserve: reserve)
                if reserve / effort.maxToolCalls >= AnswerEffort.minimumLookupCharacters + 2 {
                    XCTAssertLessThanOrEqual(effort.maxToolCalls * (size + 2), reserve, "\(effort) at \(total)")
                }
                XCTAssertLessThanOrEqual(size, AnswerEffort.lookupCharacters)
            }
        }
        // With room to spare, every lookup is full size and Focus keeps room for all ten.
        XCTAssertEqual(AnswerEffort.focus.lookupReserve(total: 80_000), 10 * AnswerEffort.lookupCharacters)
        XCTAssertEqual(AnswerEffort.normal.lookupReserve(total: 80_000), 4 * AnswerEffort.lookupCharacters)
    }

    func testFastCapsWhatThePatientChatGathers() {
        XCTAssertEqual(PatientChatAnswer.initialContextBudget(for: .fast, totalBudget: 50_000), 12_000)
        XCTAssertEqual(PatientChatAnswer.initialContextBudget(for: .fast, totalBudget: 9_000), 9_000)
        XCTAssertEqual(PatientChatAnswer.initialContextBudget(for: .normal, totalBudget: 30_000), 30_000 - 8_000)
        XCTAssertEqual(PatientChatAnswer.initialContextBudget(for: .focus, totalBudget: 70_000), 70_000 - 20_000)
    }

    func testGroupedNumbersReadTheSameEverywhere() {
        XCTAssertEqual(AnswerEffort.grouped(7_500), "7,500")
        XCTAssertEqual(AnswerEffort.grouped(12_000), "12,000")
        XCTAssertEqual(AnswerEffort.grouped(999), "999")
        XCTAssertEqual(AnswerEffort.grouped(1_234_567), "1,234,567")
    }
}
