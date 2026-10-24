import XCTest
@testable import Aletheia

final class LockCoverPolicyTests: XCTestCase {
    func testNothingCoversAnUnlockedWindow() {
        XCTAssertEqual(LockCoverPolicy.cover(appLocked: false, hasDataFolder: true, encryption: .unlocked), [])
        XCTAssertEqual(LockCoverPolicy.cover(appLocked: false, hasDataFolder: true, encryption: .disabled), [])
    }

    func testLockedAppIsCovered() {
        XCTAssertEqual(LockCoverPolicy.cover(appLocked: true, hasDataFolder: true, encryption: .unlocked), [.appLock])
    }

    func testEncryptedFolderNeedingAPassphraseIsCovered() {
        XCTAssertEqual(LockCoverPolicy.cover(appLocked: false, hasDataFolder: true, encryption: .lockedNeedsPassphrase), [.passphrase])
    }

    func testBothCoversApplyAndTheAppLockComesFirst() {
        XCTAssertEqual(
            LockCoverPolicy.cover(appLocked: true, hasDataFolder: true, encryption: .lockedNeedsPassphrase),
            [.appLock, .passphrase]
        )
        XCTAssertEqual(
            LockCoverPolicy.topCover(appLocked: true, hasDataFolder: true, encryption: .lockedNeedsPassphrase),
            .appLock
        )
        XCTAssertEqual(
            LockCoverPolicy.topCover(appLocked: false, hasDataFolder: true, encryption: .lockedNeedsPassphrase),
            .passphrase
        )
        XCTAssertNil(
            LockCoverPolicy.topCover(appLocked: false, hasDataFolder: true, encryption: .unlocked)
        )
    }

    func testNoPassphraseCoverWithoutADataFolder() {
        XCTAssertEqual(LockCoverPolicy.cover(appLocked: false, hasDataFolder: false, encryption: .lockedNeedsPassphrase), [])
    }
}

final class PatientChatWindowTests: XCTestCase {
    private let alice = Patient(name: "Alice", slug: "alice")
    private let bob = Patient(name: "Bob", slug: "bob")

    func testFindsThePatientByID() {
        XCTAssertEqual(PatientChatWindow.patient(id: bob.id, in: [alice, bob])?.name, "Bob")
    }

    func testNoIDMeansNoPatient() {
        XCTAssertNil(PatientChatWindow.patient(id: nil, in: [alice, bob]))
    }

    func testADeletedPatientIsNotFound() {
        XCTAssertNil(PatientChatWindow.patient(id: bob.id, in: [alice]))
    }

    func testLookupFollowsEditsToThePatient() {
        var renamed = alice
        renamed.name = "Alice B."
        XCTAssertEqual(PatientChatWindow.patient(id: alice.id, in: [renamed])?.name, "Alice B.")
    }

    func testMissingKeystoreIsCoveredBelowTheAppLock() {
        XCTAssertEqual(LockCoverPolicy.cover(appLocked: false, hasDataFolder: true, encryption: .keystoreMissing), [.keystoreMissing])
        XCTAssertEqual(LockCoverPolicy.cover(appLocked: true, hasDataFolder: true, encryption: .keystoreMissing), [.appLock, .keystoreMissing])
        XCTAssertEqual(LockCoverPolicy.cover(appLocked: false, hasDataFolder: false, encryption: .keystoreMissing), [])
    }

    func testContentInteractionDisabledWhileLocked() {
        XCTAssertFalse(LockCoverPolicy.contentInteractionEnabled(isLocked: true))
        XCTAssertTrue(LockCoverPolicy.resignsFirstResponder(onLockChangingTo: true))
    }

    func testContentInteractiveWhenUnlocked() {
        XCTAssertTrue(LockCoverPolicy.contentInteractionEnabled(isLocked: false))
        XCTAssertFalse(LockCoverPolicy.resignsFirstResponder(onLockChangingTo: false))
    }

    func testOnlyCommandsThatOpenContentAreDisabledWhileLocked() {
        let disabled = LockCoverPolicy.MenuCommand.allCases.filter { LockCoverPolicy.commandDisabled($0, isLocked: true) }
        XCTAssertEqual(disabled, [.openDoctor])
        for command in LockCoverPolicy.MenuCommand.allCases {
            XCTAssertFalse(LockCoverPolicy.commandDisabled(command, isLocked: false))
        }
    }

    func testLockCoverSiteAppliesThePolicy() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/AletheiaApp.swift"), encoding: .utf8)
        guard let start = source.range(of: "private struct LockCover: ViewModifier") else { return XCTFail("LockCover missing") }
        let body = String(source[start.lowerBound...])
        for needle in [
            "LockCoverPolicy.contentInteractionEnabled(isLocked: appLock.isLocked)",
            ".allowsHitTesting(interactive)", ".accessibilityHidden(!interactive)", ".disabled(!interactive)",
            "LockCoverPolicy.resignsFirstResponder(", "makeFirstResponder(nil)",
        ] {
            XCTAssertTrue(body.contains(needle), "LockCover must apply: \(needle)")
        }
        XCTAssertTrue(source.contains("LockCoverPolicy.commandDisabled(.openDoctor, isLocked: appLock.isLocked)"))
    }
}
