import Foundation

/// A saved model reply as plain answer text.
///
/// Replies are plain text as they're written: the engine never lets a model
/// write a control token (`LlamaEngine.replyBans`). Replies saved before that
/// can hold a model's hidden reasoning and its chat-template markers as text.
/// Shown, they read as part of the answer; replayed into a later prompt, the
/// model copies them. This removes both wherever a saved reply is shown or
/// sent back to the model.
enum ModelReply {
    /// `text` without reasoning spans (closed, or cut off at the end) and
    /// without chat-template markers.
    static func plain(_ text: String) -> String {
        // Every span and marker starts with "<"; most replies have none.
        guard text.contains("<") else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var out = text
        for span in reasoningSpans {
            out = out.replacingOccurrences(of: span, with: "", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: templateMarker, with: "", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A reasoning span from its opening marker to its closing one, or to the
    /// end when the reply was cut off inside it: MedGemma opens with
    /// `<unusedN>thought`, Gemma 4 with `<|channel>`, others with `<think>`.
    private static let reasoningSpans = [
        #"<unused\d+>\s*thought[\s\S]*?(?:<unused\d+>|$)"#,
        #"<\|channel>[\s\S]*?(?:<channel\|>|$)"#,
        #"<think>[\s\S]*?(?:</think>|$)"#,
    ]

    /// A chat-template marker written out as text: Gemma's `<start_of_turn>`
    /// (with the role after it), `<end_of_turn>`, `<unusedN>`, `<bos>`,
    /// `<eos>`, Gemma 4's `<|turn>` (with the role) and `<turn|>`, and the
    /// `<|…|>` markers of other templates.
    private static let templateMarker =
        #"<(?:start_of_turn>|\|turn>)(?:user|model|system)?\n?|<(?:end_of_turn|unused\d+|bos|eos)>|<turn\|>|<\|[a-z_]+\|>"#
}
