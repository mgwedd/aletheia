import Foundation

/// A rough, offline read on how hard a passphrase is to guess, for the meter
/// in the encryption setup sheet. It is guidance only: the key is always
/// stretched with PBKDF2 (see `PassphraseKDF`) whatever the rating, and no
/// rating blocks a passphrase.
///
///   passphrase ──▶ characters used ──▶ pool size ─────────────┐
///              └─▶ effective length (repeats count ¼) ─────────┴─▶ bits ──▶ weak / fair / strong
enum PassphraseStrength: Equatable {
    case weak, fair, strong

    /// Estimated bits at or above which a passphrase is "fair" / "strong".
    static let fairBits = 40.0
    static let strongBits = 60.0
    /// Below this length a passphrase is always "weak"; below the second it
    /// can be at most "fair", however varied its characters.
    static let minimumLength = 8
    static let strongMinimumLength = 12
    /// The meter is full at this many estimated bits.
    static let meterBits = 80.0

    /// A rating and a 0...1 meter fill for a passphrase.
    struct Evaluation: Equatable {
        let strength: PassphraseStrength
        /// 0 for an empty passphrase, up to 1.
        let fraction: Double
    }

    static func evaluate(_ passphrase: String) -> Evaluation {
        let chars = Array(passphrase)
        guard !chars.isEmpty else { return Evaluation(strength: .weak, fraction: 0) }
        let bits = estimatedBits(chars)
        let fraction = min(max(bits / meterBits, 0), 1)
        guard chars.count >= minimumLength else {
            // Too short to be anything but weak; keep the bar short too.
            return Evaluation(strength: .weak, fraction: min(fraction, 0.2))
        }
        var strength: PassphraseStrength = bits >= strongBits ? .strong : (bits >= fairBits ? .fair : .weak)
        if strength == .strong && chars.count < strongMinimumLength { strength = .fair }
        return Evaluation(strength: strength, fraction: fraction)
    }

    /// Characters in the pool the passphrase draws from, times an effective
    /// length where each repeat of a character already seen counts a quarter.
    private static func estimatedBits(_ chars: [Character]) -> Double {
        var pool = 0.0
        if chars.contains(where: { $0.isASCII && $0.isLowercase }) { pool += 26 }
        if chars.contains(where: { $0.isASCII && $0.isUppercase }) { pool += 26 }
        if chars.contains(where: { $0.isASCII && $0.isNumber }) { pool += 10 }
        if chars.contains(where: { $0.isASCII && !$0.isLetter && !$0.isNumber }) { pool += 33 }
        if chars.contains(where: { !$0.isASCII }) { pool += 100 }
        guard pool > 1 else { return 0 }
        let unique = Set(chars).count
        let effective = Double(unique) + 0.25 * Double(chars.count - unique)
        return effective * log2(pool)
    }
}
