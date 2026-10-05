import Foundation

/// Drives the *responsive-but-calm* streaming reveal for a chat answer.
///
/// The problem it solves: a local model emits text in bursty clumps (Ollama
/// NDJSON, llama.cpp tokens, Foundation Models snapshots), and painting each
/// burst straight to screen either machine-guns characters or lurches in
/// paragraph-sized jumps — both feel worse than a steady flow. So this splits
/// the two clocks:
///
///  - a **producer** loop reads the backend's cumulative "full text so far" as
///    fast as it arrives, only updating a target string; and
///  - a **revealer** loop, on a steady ~30ms tick, advances the *shown* prefix
///    toward that target using `StreamSmoother` (word-snapped, adaptive), so
///    the reader always sees an even, word-by-word crawl that quietly speeds up
///    when the model has raced ahead.
///
/// Stop cancels generation but keeps whatever was already revealed and persists
/// it, matching how ChatGPT/Claude's Stop behaves.
@MainActor
final class ChatStreamRunner: ObservableObject {
    /// True from `start` until the reveal has drained and finished/errored.
    @Published private(set) var isStreaming = false

    private var target = ""
    private var finishedReceiving = false
    private var failure: Error?
    private var producer: Task<Void, Never>?
    private var revealer: Task<Void, Never>?

    /// Interval between reveal ticks. Small enough to feel live, large enough
    /// that each tick reveals a readable chunk rather than one twitchy glyph.
    private let tickNanos: UInt64 = 30_000_000

    /// Consume `stream` (cumulative text) and smooth it into the UI.
    /// - onReveal: called on the main actor with the growing displayed prefix.
    /// - onError: called if the stream fails before any text arrived.
    /// - onFinish: called with the final full text once the reveal has drained
    ///   (also on Stop, with the text produced so far).
    func start(
        stream: AsyncThrowingStream<String, Error>,
        onReveal: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void,
        onFinish: @escaping (String) -> Void
    ) {
        stop()
        target = ""
        finishedReceiving = false
        failure = nil
        isStreaming = true

        producer = Task { [weak self] in
            do {
                for try await snapshot in stream {
                    if Task.isCancelled { break }
                    self?.target = snapshot
                }
            } catch {
                self?.failure = error
            }
            self?.finishedReceiving = true
        }

        revealer = Task { [weak self] in
            guard let self else { return }
            var displayed = 0
            while !Task.isCancelled {
                let next = StreamSmoother.nextCount(displayed: displayed, target: self.target)
                if next != displayed {
                    displayed = next
                    onReveal(StreamSmoother.prefix(of: self.target, count: displayed))
                }
                if self.finishedReceiving && displayed >= self.target.count { break }
                try? await Task.sleep(nanoseconds: self.tickNanos)
            }
            // Snap to the complete text so no trailing characters are dropped.
            onReveal(self.target)
            self.isStreaming = false
            self.producer = nil
            self.revealer = nil
            if let failure = self.failure, self.target.isEmpty {
                onError(failure)
            } else {
                onFinish(self.target)
            }
        }
    }

    /// Stop generation now, keep what's shown. The revealer drains the current
    /// target and then calls `onFinish`, so the partial answer is persisted.
    func stop() {
        producer?.cancel()
        finishedReceiving = true
    }
}

extension Array where Element == ChatMessage {
    /// Insert or replace a message by id, preserving its original timestamp so a
    /// streamed assistant bubble doesn't jump around as it grows.
    mutating func upsert(id: UUID, role: ChatRole, text: String) {
        if let index = firstIndex(where: { $0.id == id }) {
            self[index] = ChatMessage(id: id, role: role, text: text, date: self[index].date)
        } else {
            append(ChatMessage(id: id, role: role, text: text))
        }
    }
}
