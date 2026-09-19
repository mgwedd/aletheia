import Foundation

/// A short, curated ladder of local Ollama chat models the user can pick from —
/// lighter and faster at the top, higher quality (and heavier) at the bottom —
/// so choosing a model is a one-tap decision instead of knowing tags by heart.
/// The recommended default still comes from `ModelAdvisor` (hardware-based); this
/// just lets the therapist step up or down, or drop to a custom tag.
///
/// Kept to the same llama family `ModelAdvisor` recommends, so the ladder lines
/// up with the recommendation. Sizes are approximate download sizes.
enum OllamaCatalog {
    struct Option: Identifiable, Hashable {
        let tag: String          // e.g. "llama3.2:3b" — the Ollama model tag
        let label: String        // human-friendly name
        let approxSizeGB: Double
        let blurb: String
        var id: String { tag }
    }

    /// Ordered lightest → heaviest.
    static let options: [Option] = [
        Option(tag: "llama3.2:1b", label: "Llama 3.2 1B",
               approxSizeGB: 1.3, blurb: "Lightest and fastest. Fine on 8 GB Macs."),
        Option(tag: "llama3.2:3b", label: "Llama 3.2 3B",
               approxSizeGB: 2.0, blurb: "Balanced quality and speed for most Macs."),
        Option(tag: "llama3.1:8b", label: "Llama 3.1 8B",
               approxSizeGB: 4.7, blurb: "Higher quality; best with 16 GB+ of memory."),
    ]

    /// Sentinel selection for "type my own tag" in the picker.
    static let customTag = "__custom__"

    static func contains(_ tag: String) -> Bool {
        options.contains { $0.tag == tag }
    }

    static func option(for tag: String) -> Option? {
        options.first { $0.tag == tag }
    }
}
