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
}
