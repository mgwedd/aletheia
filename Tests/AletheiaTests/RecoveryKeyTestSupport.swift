import CryptoKit
import Foundation
@testable import Aletheia

enum RecoveryKeyTestSupport {
    /// A copy of `key` with the last word swapped for one that breaks the checksum.
    ///
    /// Swapping the last word for a fixed word still passes the 8-bit checksum
    /// for about 1 key in 256, so this checks each candidate with its own
    /// checksum math (not `RecoveryKey.entropy(from:)`) and takes the first that fails.
    static func badChecksumVariant(of key: String) -> String {
        var words = RecoveryKey.words(from: key)
        for candidate in RecoveryKey.wordlist where candidate != words[23] {
            words[23] = candidate
            if !checksumMatches(words) { return words.joined(separator: " ") }
        }
        preconditionFailure("every last word passed the checksum")
    }

    private static func checksumMatches(_ words: [String]) -> Bool {
        var bits: [Bool] = []
        for word in words {
            let index = RecoveryKey.wordToIndex[word]!
            for shift in (0..<11).reversed() { bits.append((index >> shift) & 1 == 1) }
        }
        var bytes = [UInt8](repeating: 0, count: 33)
        for (i, bit) in bits.enumerated() where bit { bytes[i / 8] |= 1 << (7 - UInt8(i % 8)) }
        return Data(SHA256.hash(data: Data(bytes[0..<32])))[0] == bytes[32]
    }
}
