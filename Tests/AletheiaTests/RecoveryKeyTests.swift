import CryptoKit
import Security
import XCTest
@testable import Aletheia

final class RecoveryKeyTests: XCTestCase {
    private let fastIterations = 100_000

    private func raw(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoveryKeyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Generation & Length

    func testGenerationEntropyAndLength() throws {
        let key = RecoveryKey.generate()
        let words = RecoveryKey.words(from: key)
        XCTAssertEqual(words.count, 24, "Recovery key must contain exactly 24 words")

        for word in words {
            XCTAssertNotNil(RecoveryKey.wordToIndex[word], "Every word must exist in the 2048-word BIP-39 wordlist")
        }

        let entropy = try RecoveryKey.entropy(from: key)
        XCTAssertEqual(entropy.count, 32, "Entropy must be 32 bytes (256 bits)")

        // Successive keys must be cryptographically random and distinct.
        let anotherKey = RecoveryKey.generate()
        XCTAssertNotEqual(key, anotherKey, "Successive generated keys must be distinct")
    }

    // MARK: - Wordlist Round-Trip & Validation

    func testBIP39OfficialZeroVectorRoundTrip() throws {
        let zeroEntropy = Data(repeating: 0, count: 32)
        let mnemonic = try RecoveryKey.keyFromEntropy(zeroEntropy)
        let expected = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"
        XCTAssertEqual(mnemonic, expected, "All-zero entropy vector matches BIP-39 test vector")

        let decodedEntropy = try RecoveryKey.entropy(from: mnemonic)
        XCTAssertEqual(decodedEntropy, zeroEntropy, "Decoding recovers original entropy")
    }

    func testRandomEntropyRoundTrip() throws {
        for _ in 0..<20 {
            var bytes = [UInt8](repeating: 0, count: 32)
            XCTAssertEqual(SecRandomCopyBytes(kSecRandomDefault, 32, &bytes), errSecSuccess)
            let original = Data(bytes)

            let mnemonic = try RecoveryKey.keyFromEntropy(original)
            let words = RecoveryKey.words(from: mnemonic)
            XCTAssertEqual(words.count, 24)

            let recovered = try RecoveryKey.entropy(from: mnemonic)
            XCTAssertEqual(recovered, original, "Entropy round-trip must be lossless")
        }
    }

    func testNormalizationHandlesWhitespaceAndCasing() throws {
        let key = RecoveryKey.generate()
        let noisy = "  \n\t " + key.uppercased().replacingOccurrences(of: " ", with: "   \n  ") + " \t "
        let normalized = try RecoveryKey.normalizeAndValidate(noisy)
        XCTAssertEqual(normalized, key.lowercased())
    }

    func testValidationRejectsWrongWordCounts() {
        let words23 = Array(repeating: "abandon", count: 23).joined(separator: " ")
        XCTAssertThrowsError(try RecoveryKey.entropy(from: words23)) { error in
            XCTAssertEqual(error as? RecoveryKey.RecoveryKeyError, .invalidWordCount(23))
        }

        let words25 = Array(repeating: "abandon", count: 25).joined(separator: " ")
        XCTAssertThrowsError(try RecoveryKey.entropy(from: words25)) { error in
            XCTAssertEqual(error as? RecoveryKey.RecoveryKeyError, .invalidWordCount(25))
        }
    }

    func testValidationRejectsUnknownWords() {
        var words = RecoveryKey.words(from: RecoveryKey.generate())
        words[5] = "notabipword"
        let badKey = words.joined(separator: " ")
        XCTAssertThrowsError(try RecoveryKey.entropy(from: badKey)) { error in
            XCTAssertEqual(error as? RecoveryKey.RecoveryKeyError, .unknownWord("notabipword"))
        }
    }

    func testValidationRejectsBadChecksum() {
        var words = RecoveryKey.words(from: RecoveryKey.generate())
        // Replacing the last word (which carries the checksum) with a different valid word breaks checksum.
        let replacement = words[23] == "abandon" ? "zoo" : "abandon"
        words[23] = replacement
        let badChecksumKey = words.joined(separator: " ")
        XCTAssertThrowsError(try RecoveryKey.entropy(from: badChecksumKey)) { error in
            XCTAssertEqual(error as? RecoveryKey.RecoveryKeyError, .invalidChecksum)
        }
    }

    // MARK: - Keystore Unlocking with Recovery Key

    func testUnlockingWithRecoveryKey() throws {
        let recoveryKey = RecoveryKey.generate()
        let (keystore, dek) = try Keystore.create(
            passphrase: "correct horse battery staple",
            recoveryKey: recoveryKey,
            iterations: fastIterations
        )

        XCTAssertTrue(keystore.hasRecoveryKey)
        let unlocked = try keystore.unlock(recoveryKey: recoveryKey)
        XCTAssertEqual(raw(unlocked), raw(dek), "Recovery key must unlock the exact same DEK")

        // Passphrase still unlocks the same DEK.
        let unlockedViaPassphrase = try keystore.unlock(passphrase: "correct horse battery staple")
        XCTAssertEqual(raw(unlockedViaPassphrase), raw(dek))
    }

    func testWrongRecoveryKeyThrows() throws {
        let recoveryKey = RecoveryKey.generate()
        let (keystore, _) = try Keystore.create(
            passphrase: "my-passphrase",
            recoveryKey: recoveryKey,
            iterations: fastIterations
        )

        let anotherValidKey = RecoveryKey.generate()
        XCTAssertThrowsError(try keystore.unlock(recoveryKey: anotherValidKey)) { error in
            XCTAssertEqual(error as? Keystore.KeystoreError, .wrongRecoveryKey)
        }
    }

    // MARK: - Replacing Recovery Key

    func testReplacingRecoveryKeyInvalidatesOldOne() throws {
        let oldKey = RecoveryKey.generate()
        let (keystore, dek) = try Keystore.create(
            passphrase: "passphrase",
            recoveryKey: oldKey,
            iterations: fastIterations
        )

        let newKey = RecoveryKey.generate()
        let oldSlot = try XCTUnwrap(keystore.wrappings.first { $0.kind == .recoveryKey })
        let updatedKeystore = try keystore
            .addingRecoveryKeyWrapping(dek: dek, recoveryKey: newKey, iterations: fastIterations)
            .removingWrapping(id: oldSlot.id)

        // New key unlocks.
        let unlockedNew = try updatedKeystore.unlock(recoveryKey: newKey)
        XCTAssertEqual(raw(unlockedNew), raw(dek))

        // Old key fails.
        XCTAssertThrowsError(try updatedKeystore.unlock(recoveryKey: oldKey)) { error in
            XCTAssertEqual(error as? Keystore.KeystoreError, .wrongRecoveryKey)
        }

        // Passphrase still unlocks.
        let unlockedPassphrase = try updatedKeystore.unlock(passphrase: "passphrase")
        XCTAssertEqual(raw(unlockedPassphrase), raw(dek))
    }

    func testKeystoreKeepsBothPassphraseAndRecoveryKeySlots() throws {
        let recoveryKey = RecoveryKey.generate()
        let (keystore, _) = try Keystore.create(
            passphrase: "passphrase",
            recoveryKey: recoveryKey,
            iterations: fastIterations
        )

        XCTAssertEqual(keystore.wrappings.count, 2)
        XCTAssertEqual(keystore.wrappings.filter { $0.kind == .passphrase }.count, 1)
        XCTAssertEqual(keystore.wrappings.filter { $0.kind == .recoveryKey }.count, 1)
        XCTAssertTrue(keystore.hasRecoveryKey)
    }

    // MARK: - EncryptionManager Integration

    func testEncryptionManagerRecoveryKeyWorkflow() throws {
        let manager = EncryptionManager(dataRootProvider: { self.tempRoot })
        let recoveryKey = RecoveryKey.generate()

        try manager.enable(passphrase: "master-passphrase", recoveryKey: recoveryKey, iterations: fastIterations)
        XCTAssertEqual(manager.state, .unlocked)
        XCTAssertTrue(manager.hasRecoveryKey)

        // Lock manager.
        manager.lock()
        XCTAssertEqual(manager.state, .lockedNeedsPassphrase)

        // Unlock with recovery key.
        try manager.unlock(recoveryKey: recoveryKey)
        XCTAssertEqual(manager.state, .unlocked)

        // Replace recovery key.
        let brandNewKey = try manager.replaceRecoveryKey(iterations: fastIterations)
        XCTAssertNotEqual(brandNewKey, recoveryKey)
        XCTAssertTrue(manager.hasRecoveryKey)

        // Lock again.
        manager.lock()
        XCTAssertEqual(manager.state, .lockedNeedsPassphrase)

        // Old recovery key fails.
        XCTAssertThrowsError(try manager.unlock(recoveryKey: recoveryKey))

        // New recovery key unlocks.
        try manager.unlock(recoveryKey: brandNewKey)
        XCTAssertEqual(manager.state, .unlocked)
    }

    /// A folder encrypted before recovery keys existed has only a passphrase
    /// slot; creating a recovery key adds one without touching the passphrase.
    func testCreatingRecoveryKeyForFolderWithoutOne() throws {
        let manager = EncryptionManager(dataRootProvider: { self.tempRoot })
        try manager.enable(passphrase: "legacy-passphrase", iterations: fastIterations)
        XCTAssertFalse(manager.hasRecoveryKey)

        let key = try manager.replaceRecoveryKey(iterations: fastIterations)
        XCTAssertTrue(manager.hasRecoveryKey)

        manager.lock()
        try manager.unlock(recoveryKey: key)
        XCTAssertEqual(manager.state, .unlocked)
        manager.lock()
        try manager.unlock(passphrase: "legacy-passphrase")
        XCTAssertEqual(manager.state, .unlocked)
    }
}
