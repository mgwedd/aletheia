extension Copy {
    static let aiNeverReadsMyNotes = "the AI never reads them"
    static let analyzing = "Analyzing"
    static let preparingTheAnswer = "Preparing the answer"
    static let accuracyNotice = "AI generated responses can be inaccurate. Double-check responses."
    static func readingPart(_ part: Int, of total: Int) -> String { "Reading the session · part \(part) of \(total)" }
    static let askEmptyTitle = "Ask a question about this session"
    static let newChatTitle = "New chat"
    static let readLead = "Read:"
    static let sourcesLead = "Sources:"
    static let patientGone = "This patient is no longer available."
}

extension Copy {
    static let depthLabel = "Depth"
    static let questionLead = "Therapist's question:"
    static let noteFormatStillApplies = "The note's own format still applies."
    static let onItsOwnTerms = "Answer the latest question on its own terms."
    static let earlierTurnsAsContext = "use earlier turns only as context"
    static func askTarget(_ depth: Depth) -> String {
        switch depth {
        case .concise: "one to three sentences"
        case .natural: "a short paragraph or two"
        case .detailed: "full answer"
        }
    }
}
