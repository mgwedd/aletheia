#if canImport(llama)
import Foundation
import llama
import os

private let log = Logger(subsystem: "com.aletheia", category: "Llama")

/// The one place a (system, prompt) pair becomes model tokens, shared by
/// `LlamaEngine` and `LlamaAssistant`. Instruct models only answer when the
/// prompt is wrapped in their chat template; fed raw text they emit EOG
/// immediately.
enum LlamaPrompt {
    /// Formats `system`/`prompt` with the given chat template. Returns nil when
    /// llama.cpp doesn't support the template, so the caller falls back to the
    /// raw prompt.
    static func applyTemplate(_ tmpl: String, system: String, prompt: String) -> String? {
        applyTemplate(tmpl, system: system, messages: [PromptTurn(role: .user, text: prompt)])
    }

    /// Formats `system` and a user/assistant conversation (ending with the
    /// user turn to answer) with the given chat template, adding the opening
    /// of the model's reply. Nil when llama.cpp doesn't support the template.
    static func applyTemplate(_ tmpl: String, system: String, messages: [PromptTurn]) -> String? {
        let sys = system.trimmingCharacters(in: .whitespacesAndNewlines)
        var roles: [(role: String, content: String)] = sys.isEmpty ? [] : [("system", sys)]
        roles += messages.map { ($0.role == .user ? "user" : "assistant", $0.text) }

        // The C strings must outlive the call; free the strdup'd copies after.
        let cRoles = roles.map { (strdup($0.role), strdup($0.content)) }
        defer { cRoles.forEach { free($0.0); free($0.1) } }
        let cMessages = cRoles.map { llama_chat_message(role: $0.0, content: $0.1) }

        // The return is the full length needed (header contract); if it exceeds
        // the buffer, grow and re-apply. Negative means an unsupported template.
        var buffer = [CChar](repeating: 0, count: max(256, 2 * roles.reduce(0) { $0 + $1.content.utf8.count }))
        var needed = llama_chat_apply_template(tmpl, cMessages, cMessages.count, true, &buffer, Int32(buffer.count))
        if needed > Int32(buffer.count) {
            buffer = [CChar](repeating: 0, count: Int(needed))
            needed = llama_chat_apply_template(tmpl, cMessages, cMessages.count, true, &buffer, Int32(buffer.count))
        }
        guard needed >= 0, needed <= Int32(buffer.count) else {
            // llama_chat_apply_template has no Jinja engine and only knows a
            // fixed list of templates; Gemma 4's (`<|turn>` markers) isn't on
            // it, so render that one layout directly.
            if tmpl.contains("<|turn>") {
                let systemTurn = sys.isEmpty ? "" : "<|turn>system\n\(sys)<turn|>\n"
                let turns = messages.map { turn in
                    "<|turn>\(turn.role == .user ? "user" : "model")\n"
                        + turn.text.trimmingCharacters(in: .whitespacesAndNewlines) + "<turn|>\n"
                }
                return "<bos>\(systemTurn)\(turns.joined())<|turn>model\n"
            }
            log.notice("Chat template unsupported (code \(needed)); using the raw prompt")
            return nil
        }
        return String(decoding: buffer[0..<Int(needed)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The pre-template behavior, used when the model has no usable template.
    static func rawPrompt(system: String, prompt: String) -> String {
        let sys = system.trimmingCharacters(in: .whitespacesAndNewlines)
        return sys.isEmpty ? prompt : "System: \(sys)\n\n\(prompt)"
    }

    /// A run of prompt text and whether the tokenizer may read control-token
    /// spellings (`<|eot_id|>`, `<start_of_turn>`) in it as the real tokens.
    struct Segment: Equatable {
        let text: String
        let parseSpecial: Bool
    }

    /// Stand-ins for the system text, earlier turns and the prompt while the
    /// chat template renders the turn markers around them.
    static let systemSlot = "ALETHEIA-SYSTEM-SLOT-7F3A"
    static let promptSlot = "ALETHEIA-PROMPT-SLOT-7F3A"
    static func turnSlot(_ index: Int) -> String { "ALETHEIA-TURN-\(index)-SLOT-7F3A" }

    /// Splits a template rendered with the slot markers into segments: the
    /// template's own text may carry control tokens; `system` and `prompt`
    /// (transcripts, notes, chat input, all of it) never do. Both are trimmed,
    /// as the shipped models' templates trim message text. Nil when a marker
    /// is missing or repeated, so the caller falls back to the raw prompt.
    static func segments(skeleton: String, system: String, prompt: String) -> [Segment]? {
        segments(skeleton: skeleton, system: system, messages: [PromptTurn(role: .user, text: prompt)])
    }

    /// The same for a whole conversation: every turn's text, like the system
    /// text, is plain text; the last turn fills `promptSlot`, earlier ones
    /// `turnSlot(i)`.
    static func segments(skeleton: String, system: String, messages: [PromptTurn]) -> [Segment]? {
        let sys = system.trimmingCharacters(in: .whitespacesAndNewlines)
        var fills: [(marker: String, content: String)] = []
        if !sys.isEmpty { fills.append((systemSlot, sys)) } else if skeleton.contains(systemSlot) { return nil }
        for (index, turn) in messages.enumerated() {
            let marker = index == messages.count - 1 ? promptSlot : turnSlot(index)
            fills.append((marker, turn.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        var slots: [(range: Range<String.Index>, content: String)] = []
        for fill in fills {
            let found = skeleton.ranges(of: fill.marker)
            guard found.count == 1 else { return nil }
            slots.append((found[0], fill.content))
        }
        slots.sort { $0.range.lowerBound < $1.range.lowerBound }
        var out: [Segment] = []
        var cursor = skeleton.startIndex
        for slot in slots {
            out.append(Segment(text: String(skeleton[cursor..<slot.range.lowerBound]), parseSpecial: true))
            out.append(Segment(text: slot.content, parseSpecial: false))
            cursor = slot.range.upperBound
        }
        out.append(Segment(text: String(skeleton[cursor...]), parseSpecial: true))
        return out.filter { !$0.text.isEmpty }
    }

    /// The segments for the model's reply to `system`/`prompt`: templated with
    /// `tmpl` when llama.cpp supports it, otherwise the raw prompt as plain text.
    static func segments(template tmpl: String?, system: String, prompt: String) -> [Segment] {
        segments(template: tmpl, system: system, turns: [], prompt: prompt)
    }

    /// The same after earlier chat turns, each sent as a turn of the template.
    static func segments(template tmpl: String?, system: String, turns: [PromptTurn], prompt: String) -> [Segment] {
        let messages = PromptTurn.conversation(turns, then: prompt)
        let hasSystem = !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let placeholders = messages.enumerated().map { index, turn in
            PromptTurn(role: turn.role, text: index == messages.count - 1 ? promptSlot : turnSlot(index))
        }
        if let tmpl,
           let skeleton = applyTemplate(tmpl, system: hasSystem ? systemSlot : "", messages: placeholders),
           let split = segments(skeleton: skeleton, system: system, messages: messages) {
            return split
        }
        return [Segment(text: rawPrompt(system: system, prompt: PromptTurn.flattened(turns, then: prompt)), parseSpecial: false)]
    }

    /// Tokens for the model's reply to `system`/`prompt`: templated with the
    /// model's own embedded template when it has a usable one, otherwise the
    /// raw prompt. Only the template's own markers are parsed as control
    /// tokens. Returns nil if tokenization fails.
    static func tokens(
        model: OpaquePointer, vocab: OpaquePointer, system: String, turns: [PromptTurn] = [], prompt: String
    ) -> [llama_token]? {
        let tmplPtr = llama_model_chat_template(model, nil)
        if tmplPtr == nil { log.notice("Model has no chat template; using the raw prompt") }
        let parts = segments(template: tmplPtr.map { String(cString: $0) }, system: system, turns: turns, prompt: prompt)
        var addSpecial = true
        // Many templates already begin with the literal BOS token, which
        // parse_special tokenizes to BOS; don't add a second one.
        let bos = llama_vocab_bos(vocab)
        if bos >= 0, let bosText = llama_vocab_get_text(vocab, bos),
           let first = parts.first, first.parseSpecial, first.text.hasPrefix(String(cString: bosText)) {
            addSpecial = false
        }

        var tokens: [llama_token] = []
        for (index, part) in parts.enumerated() {
            guard let piece = tokenize(part, vocab: vocab, addSpecial: addSpecial && index == 0) else { return nil }
            tokens += piece
        }
        return tokens.isEmpty ? nil : tokens
    }

    /// The one tokenizer call: a segment's own flag decides control-token parsing.
    private static func tokenize(_ segment: Segment, vocab: OpaquePointer, addSpecial: Bool) -> [llama_token]? {
        let length = Int32(segment.text.utf8.count)
        // llama_tokenize returns the negated token count when the buffer is too small.
        let needed = -llama_tokenize(vocab, segment.text, length, nil, 0, addSpecial, segment.parseSpecial)
        guard needed > 0 else { return addSpecial || length > 0 ? nil : [] }
        var tokens = [llama_token](repeating: 0, count: Int(needed))
        guard llama_tokenize(vocab, segment.text, length, &tokens, needed, addSpecial, segment.parseSpecial) >= 0 else { return nil }
        return tokens
    }
}
#endif
