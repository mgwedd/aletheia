import Foundation

/// How much of the previous request's KV cache a new prompt can keep. Pure
/// math, so it is testable without a model.
///
/// The engine keeps the tokens it last fed the model. A new prompt that starts
/// with the same tokens (the same system prompt and session, a follow-up
/// question) only needs the rest read: the cache is cut back to the first token
/// that differs and the model reads from there. The result is the same as
/// reading the whole prompt, because every kept position holds exactly what a
/// full read would have put there.
enum LlamaPromptCache {
    /// How many leading tokens of `prompt` can be kept from the cache.
    ///
    /// - `cached`: the tokens in the cache, in position order.
    /// - `cacheStart`: the lowest position the cache still holds
    ///   (`llama_memory_seq_pos_min`), -1 when empty. Above 0 means a
    ///   sliding-window cache has dropped early positions.
    /// - `slidingWindow`: the model's attention window (`llama_model_n_swa`),
    ///   0 when it has none.
    ///
    /// At least one prompt token is always left to read, since its logits pick
    /// the first reply token. When a sliding-window cache no longer holds what
    /// the new tokens look back at, nothing is kept and the prompt is read in
    /// full: slower, never wrong.
    static func reusableTokens(cached: [Int32], prompt: [Int32], cacheStart: Int32, slidingWindow: Int32) -> Int {
        let limit = min(cached.count, prompt.count - 1)
        var shared = 0
        while shared < limit, cached[shared] == prompt[shared] { shared += 1 }
        guard shared > 0, cacheStart >= 0 else { return 0 }
        if cacheStart > 0 {
            // The first new token at position `shared` attends back to
            // `shared - slidingWindow`; the cache must still hold it.
            guard slidingWindow > 0, Int(cacheStart) <= max(0, shared - Int(slidingWindow)) else { return 0 }
        }
        return shared
    }
}
