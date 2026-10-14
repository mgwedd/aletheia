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
        let sys = system.trimmingCharacters(in: .whitespacesAndNewlines)
        var roles: [(role: String, content: String)] = sys.isEmpty ? [] : [("system", sys)]
        roles.append(("user", prompt))

        // The C strings must outlive the call; free the strdup'd copies after.
        let cRoles = roles.map { (strdup($0.role), strdup($0.content)) }
        defer { cRoles.forEach { free($0.0); free($0.1) } }
        let messages = cRoles.map { llama_chat_message(role: $0.0, content: $0.1) }

        // The return is the full length needed (header contract); if it exceeds
        // the buffer, grow and re-apply. Negative means an unsupported template.
        var buffer = [CChar](repeating: 0, count: max(256, 2 * roles.reduce(0) { $0 + $1.content.utf8.count }))
        var needed = llama_chat_apply_template(tmpl, messages, messages.count, true, &buffer, Int32(buffer.count))
        if needed > Int32(buffer.count) {
            buffer = [CChar](repeating: 0, count: Int(needed))
            needed = llama_chat_apply_template(tmpl, messages, messages.count, true, &buffer, Int32(buffer.count))
        }
        guard needed >= 0, needed <= Int32(buffer.count) else {
            // llama_chat_apply_template has no Jinja engine and only knows a
            // fixed list of templates; Gemma 4's (`<|turn>` markers) isn't on
            // it, so render that one layout directly.
            if tmpl.contains("<|turn>") {
                let systemTurn = sys.isEmpty ? "" : "<|turn>system\n\(sys)<turn|>\n"
                return "<bos>\(systemTurn)<|turn>user\n\(prompt.trimmingCharacters(in: .whitespacesAndNewlines))<turn|>\n<|turn>model\n"
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

    /// Tokens for the model's reply to `system`/`prompt`: templated with the
    /// model's own embedded template when it has a usable one, otherwise the
    /// raw prompt. Returns nil if tokenization fails.
    static func tokens(model: OpaquePointer, vocab: OpaquePointer, system: String, prompt: String) -> [llama_token]? {
        var text = rawPrompt(system: system, prompt: prompt)
        var addSpecial = true
        if let tmplPtr = llama_model_chat_template(model, nil),
           let templated = applyTemplate(String(cString: tmplPtr), system: system, prompt: prompt) {
            text = templated
            // Many templates already begin with the literal BOS token, which
            // parse_special tokenizes to BOS; don't add a second one.
            let bos = llama_vocab_bos(vocab)
            if bos >= 0, let bosText = llama_vocab_get_text(vocab, bos), text.hasPrefix(String(cString: bosText)) {
                addSpecial = false
            }
        }

        let length = Int32(text.utf8.count)
        // llama_tokenize returns the negated token count when the buffer is too small.
        let needed = -llama_tokenize(vocab, text, length, nil, 0, addSpecial, true)
        guard needed > 0 else { return nil }
        var tokens = [llama_token](repeating: 0, count: Int(needed))
        guard llama_tokenize(vocab, text, length, &tokens, needed, addSpecial, true) >= 0 else { return nil }
        return tokens
    }
}
#endif
