import Foundation

/// Transcripts the journeys start from, in the stored form.
enum SessionContent {
    /// A session of `minutes` minutes: a turn every five, you and the client
    /// taking it in turn, so it is long enough to be read in parts.
    static func longTranscript(minutes: Int = 40) -> String {
        stride(from: 0, through: minutes, by: 5).enumerated().map { index, minute in
            let who = index % 2 == 0 ? "You" : "Call audio"
            let words = index % 2 == 0
                ? "How has the sleep been since we last met, and what has changed at work?"
                : "Still poor. I wake at four and the insomnia gets worse when the deadline at work comes up."
            return String(format: "[%02d:%02d] %@: %@", minute, 0, who, words)
        }.joined(separator: "\n")
    }

    /// A short session that mentions insomnia and work.
    static let shortTranscript = """
    [00:05] You: How has the sleep been since we last met?
    [00:20] Call audio: Still poor. The insomnia gets worse when the deadline at work comes up.
    [00:45] You: What helps when you wake at four?
    """

    /// One long turn of `speaker` ("You" or "Call audio"), many lines when it wraps.
    static func longTurn(by speaker: String) -> String {
        let speech = Array(repeating: "I keep coming back to how the week went and what I could have said differently.", count: 14)
            .joined(separator: " ")
        return "[00:10] \(speaker): \(speech)"
    }
}
