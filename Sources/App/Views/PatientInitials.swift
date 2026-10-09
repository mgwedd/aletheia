import Foundation

/// The one- or two-letter monogram shown in a patient's avatar.
///
/// The first letter of the first word and, when there is more than one word,
/// the first letter of the last word, uppercased. An empty or blank name gives
/// "?". Pure, so it's unit-tested.
enum PatientInitials {
    static func from(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        guard let first = words.first, let firstLetter = first.first else { return "?" }
        guard words.count > 1, let last = words.last, let lastLetter = last.first else {
            return letter(firstLetter)
        }
        return letter(firstLetter) + letter(lastLetter)
    }

    /// One uppercased letter. Uppercasing can expand a character ("ß" becomes
    /// "SS"), so only the first is kept to hold the monogram to a letter a word.
    private static func letter(_ character: Character) -> String {
        String(String(character).uppercased().prefix(1))
    }
}
