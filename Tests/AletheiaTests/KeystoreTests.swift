import CryptoKit
import XCTest
@testable import Aletheia

final class KeystoreTests: XCTestCase {
    // Real keystores use 600k PBKDF2 iterations; tests use a tiny count so the
    // suite stays fast. The count travels with each slot, so this is faithful.
    private let fastIterations = 1_000

    private func raw(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeystoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testCreateThenUnlockYieldsSameDEK() throws {
        let (keystore, dek) = try Keystore.create(passphrase: "correct horse battery staple", iterations: fastIterations)
        let unlocked = try keystore.unlock(passphrase: "correct horse battery staple")
        XCTAssertEqual(raw(unlocked), raw(dek), "unlocking must recover the exact DEK")
    }

    func testWrongPassphraseThrows() throws {
        let (keystore, _) = try Keystore.create(passphrase: "right", iterations: fastIterations)
        XCTAssertThrowsError(try keystore.unlock(passphrase: "wrong")) { error in
            XCTAssertEqual(error as? Keystore.KeystoreError, .wrongPassphrase)
        }
    }

    func testDEKNeverAppearsInSerializedForm() throws {
        let (keystore, dek) = try Keystore.create(passphrase: "pw", iterations: fastIterations)
        let json = try JSONEncoder().encode(keystore)
        // The raw DEK bytes must not be findable anywhere in the serialized keystore.
        XCTAssertNil(json.range(of: raw(dek)), "the DEK must only ever be stored wrapped")
    }

    func testSecondPassphraseUnlocksSameDEK() throws {
        let (keystore, dek) = try Keystore.create(passphrase: "first", iterations: fastIterations)
        let twoSlots = try keystore.addingPassphraseWrapping(dek: dek, passphrase: "second", iterations: fastIterations)
        XCTAssertEqual(twoSlots.wrappings.count, 2)
        XCTAssertEqual(raw(try twoSlots.unlock(passphrase: "first")), raw(dek))
        XCTAssertEqual(raw(try twoSlots.unlock(passphrase: "second")), raw(dek))
    }

    func testRemoveWrappingKeepsOthersWorking() throws {
        let (keystore, dek) = try Keystore.create(passphrase: "first", iterations: fastIterations)
        let twoSlots = try keystore.addingPassphraseWrapping(dek: dek, passphrase: "second", iterations: fastIterations)
        let firstID = twoSlots.wrappings[0].id
        let oneSlot = try twoSlots.removingWrapping(id: firstID)
        XCTAssertEqual(oneSlot.wrappings.count, 1)
        XCTAssertThrowsError(try oneSlot.unlock(passphrase: "first"))
        XCTAssertEqual(raw(try oneSlot.unlock(passphrase: "second")), raw(dek))
    }

    func testCannotRemoveLastWrapping() throws {
        let (keystore, _) = try Keystore.create(passphrase: "only", iterations: fastIterations)
        XCTAssertThrowsError(try keystore.removingWrapping(id: keystore.wrappings[0].id)) { error in
            XCTAssertEqual(error as? Keystore.KeystoreError, .cannotRemoveLastWrapping)
        }
    }

    func testWriteAndLoadRoundTrip() throws {
        let (keystore, dek) = try Keystore.create(passphrase: "disk pw", iterations: fastIterations)
        try keystore.write(to: tempRoot)
        XCTAssertTrue(Keystore.exists(at: tempRoot))
        let loaded = try XCTUnwrap(Keystore.load(from: tempRoot))
        XCTAssertEqual(loaded, keystore)
        XCTAssertEqual(raw(try loaded.unlock(passphrase: "disk pw")), raw(dek))
    }

    func testLoadMissingReturnsNil() {
        XCTAssertFalse(Keystore.exists(at: tempRoot))
        XCTAssertNil(Keystore.load(from: tempRoot))
    }

    // MARK: - KDF

    func testKDFIsDeterministicForSameInputs() throws {
        let salt = PassphraseKDF.randomSalt()
        let a = try PassphraseKDF.deriveKey(passphrase: "pw", salt: salt, iterations: fastIterations)
        let b = try PassphraseKDF.deriveKey(passphrase: "pw", salt: salt, iterations: fastIterations)
        XCTAssertEqual(raw(a), raw(b))
    }

    func testKDFDiffersBySalt() throws {
        let a = try PassphraseKDF.deriveKey(passphrase: "pw", salt: PassphraseKDF.randomSalt(), iterations: fastIterations)
        let b = try PassphraseKDF.deriveKey(passphrase: "pw", salt: PassphraseKDF.randomSalt(), iterations: fastIterations)
        XCTAssertNotEqual(raw(a), raw(b))
    }

    func testKDFRejectsEmptyPassphrase() {
        XCTAssertThrowsError(try PassphraseKDF.deriveKey(passphrase: "", salt: PassphraseKDF.randomSalt(), iterations: fastIterations))
    }

    func testDerivedKeyIs256Bits() throws {
        let key = try PassphraseKDF.deriveKey(passphrase: "pw", salt: PassphraseKDF.randomSalt(), iterations: fastIterations)
        XCTAssertEqual(raw(key).count, 32)
    }
}
