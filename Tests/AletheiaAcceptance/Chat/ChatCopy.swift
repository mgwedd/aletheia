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
    static let questionLead = "Question:"
    static let noteFormatStillApplies = "The note's own format still applies."
    static let onItsOwnTerms = "Answer the latest question on its own terms."
    static let earlierTurnsAsContext = "use earlier turns only as context"
    static let writeToYou = "Write to them as \"you\""
    static let sayEachPointOnce = "Say each point once"
    static let noSecondList = "don't restate a list as a second list"
    static let noUnaskedActionItems = "Suggest action items or homework only if they were agreed or you are asked."
    static let thinSessionShortAnswer = "A thin session gets a short answer."
    static func askTarget(_ depth: Depth) -> String {
        switch depth {
        case .concise: "one to three sentences"
        case .natural: "a short paragraph or two"
        case .detailed: "full answer"
        }
    }
}

extension Copy {
    /// A model's hidden reasoning, as a saved reply once held it.
    static let hiddenReasoning = "The therapist wants it short."
    static let reasoningOpen = "<unused94>thought "
    static let reasoningClose = "<unused95>"
    static let endOfTurn = "<end_of_turn>"
    static let summaryDidNotFinish =
        "The summary didn't finish, so the conversation was kept as it was. "
        + "Try Compact again, or name what to keep, like /compact medication."
    /// Words in the request that asks the AI to summarize the conversation.
    static let summaryRequest = "notes on this chat that will replace it"
}
