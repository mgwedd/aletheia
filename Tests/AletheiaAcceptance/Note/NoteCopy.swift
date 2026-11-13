extension Copy {
    static let processingTranscript = "Processing transcript"
    static let coverageLead = "Read:"
    static let quotedLines = "transcript lines quoted word for word"
    static let wholeSessionSummary = "every part of the session, summarized"
    static let wholeTranscript = "the whole transcript, word for word"
    static let noteReadyTitle = "SOAP note ready"
    static let followUpLookup = "follow-up lookup"
    static let depthChoices = ["Concise", "Natural", "Detailed"]
    static let effortChoices = ["Fast", "Normal", "Focus"]
    static let formatNames = ["Summary", "SOAP", "DAP", "BIRP", "GIRP"]
    static let myNotes = "My Notes"
    static let soapSections = ["Subjective", "Objective", "Assessment", "Plan"]
    static let waitingForChat = "Waiting for the chat answer to finish…"
    static let notDownloadedTitle = "The AI model isn't downloaded"
    static let downloadModel = "Download Model"
    static let copied = "Copied"
    static let bullet = "•"
    /// What a check sends back when it copies the session instead of correcting the note.
    static let echoedTranscript = "<transcript>\n[15:44] You: Trust, yes.\n[15:50] Jane: It has been hard.\n</transcript>"
    static let echoedLine = "[15:44]"
    static let checkCopiedSource = "The check returned the session material instead of a note"
    static let summaryTask = "Now write a summary of the whole session"
    static let summaryLengths: [Depth: String] = [.concise: "80–150 words", .natural: "150–300 words", .detailed: "300–600 words"]
    /// A Summary of 20 ten-word sentences (200 words) that ends with a risk statement.
    static let overlongSummary = (1...20).map { "Topic \($0) came up and was discussed at some length." }
        .joined(separator: " ") + " " + riskSentence
    static let riskSentence = "The client denied suicidal thoughts."
    /// The last sentence within Concise's 150 words, and the first past it.
    static let lastSentenceWithinConcise = "Topic 15 came up"
    static let firstSentencePastConcise = "Topic 16 came up"
}

extension Copy {
    static let summaryReadyTitle = "Summary ready"
}
