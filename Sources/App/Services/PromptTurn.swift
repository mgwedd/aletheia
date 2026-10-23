import Foundation

/// One earlier turn of a chat, sent to the model as a real turn of its chat
/// template (not pasted into the prompt text), so the therapist's own requests
/// ("answer in bullets from now on") read as hers and keep applying.
struct PromptTurn: Equatable {
    enum Role: Equatable { case user, assistant }

    let role: Role
    let text: String

    /// The chat messages after the latest summary, as turns, leaving out the
    /// question being sent now (the chat views append it before sending).
    static func recent(_ history: [ChatMessage], question: String? = nil) -> [PromptTurn] {
        var recent = ChatMemory.remembered(history).recent
        if let last = recent.last, last.role == .user, last.text == question { recent.removeLast() }
        return recent.compactMap { message in
            switch message.role {
            case .user: return PromptTurn(role: .user, text: message.text)
            case .assistant: return PromptTurn(role: .assistant, text: message.text)
            case .summary: return nil
            }
        }
    }

    /// `turns` then `prompt` as a list a chat template accepts: user and
    /// assistant alternating, starting and ending with a user turn. Two turns
    /// in a row from the same side are joined (an unanswered question, say),
    /// and a reply with no question before it gets an empty one. Nothing is
    /// dropped but blank turns.
    static func conversation(_ turns: [PromptTurn], then prompt: String) -> [PromptTurn] {
        var out: [PromptTurn] = []
        for turn in turns + [PromptTurn(role: .user, text: prompt)] {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || turn.role == .user else { continue }
            if let last = out.last, last.role == turn.role {
                out[out.count - 1] = PromptTurn(role: turn.role, text: [last.text, text].filter { !$0.isEmpty }.joined(separator: "\n\n"))
            } else {
                if out.isEmpty, turn.role == .assistant { out.append(PromptTurn(role: .user, text: "")) }
                out.append(PromptTurn(role: turn.role, text: text))
            }
        }
        return out
    }

    /// The turns as plain text, for backends without chat turns and for sizing.
    static func transcript(_ turns: [PromptTurn]) -> String {
        turns.map { "\($0.role == .user ? "Therapist" : "Assistant"): \($0.text)" }.joined(separator: "\n")
    }

    /// `prompt` with the turns written out before it: what a backend that only
    /// takes one prompt is sent.
    static func flattened(_ turns: [PromptTurn], then prompt: String) -> String {
        turns.isEmpty ? prompt : "Conversation so far:\n\(transcript(turns))\n\n\(prompt)"
    }
}
