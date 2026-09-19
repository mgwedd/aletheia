import Foundation
import CryptoKit

/// SHA-256 over a file on disk, computed by streaming the file in chunks so a
/// multi-gigabyte model never has to sit in memory at once.
///
/// This is the integrity gate for on-device model weights: the built-in LLM and
/// Whisper models are downloaded over the network, and a therapist's Mac must
/// never load weights that were corrupted in transit or swapped by a
/// man-in-the-middle. Downloads are checked against a digest pinned in the app
/// before the file is accepted.
enum ModelDigest {
    /// Lowercase hex SHA-256 of the file at `url`. Reads in `chunkSize` blocks
    /// (default 1 MiB) and throws if the file can't be opened or read.
    static func sha256(ofFileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// True when the file's SHA-256 equals `expected` (compared case-insensitively,
    /// so a pinned digest can be written in either case). Throws if the file
    /// can't be hashed.
    static func matches(fileAt url: URL, expected: String) throws -> Bool {
        try sha256(ofFileAt: url).caseInsensitiveCompare(expected) == .orderedSame
    }
}
