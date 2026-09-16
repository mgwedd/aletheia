import Foundation

/// A UUID that's deterministic for a given string.
///
/// `SessionRecord` is reconstructed from disk on every `listSessions()`
/// call rather than being loaded from a persisted id — its folder name
/// (already unique within a patient) is the only stable handle available.
/// Minting a random `UUID()` each time would silently break SwiftUI's
/// list-selection and diffing identity every time the list refreshes
/// (e.g. right after recording or transcribing). Deriving the id from the
/// folder name instead keeps it stable for as long as the folder exists.
enum StableID {
    static func uuid(from string: String) -> UUID {
        let high = fnv1a(string, seed: 0xcbf29ce484222325)
        let low = fnv1a(string, seed: 0x84222325cbf29ce4)

        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        withUnsafeBytes(of: high.bigEndian) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: low.bigEndian) { bytes.append(contentsOf: $0) }

        // Set the version (4) and variant bits so this is a well-formed UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }

    /// FNV-1a — simple, dependency-free, and (unlike Swift's `hashValue`)
    /// deterministic across runs, which is what makes this usable as a
    /// stable identifier rather than just an in-process one.
    private static func fnv1a(_ string: String, seed: UInt64) -> UInt64 {
        var hash = seed
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
