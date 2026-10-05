import SwiftUI

/// Reusable chat UI shared by the per-session and cross-patient chat
/// features. Deliberately dumb: the caller owns the message list and
/// decides what "send" means (which transcript/context to include).
struct ChatPaneView: View {
    let title: String
    @Binding var messages: [ChatMessage]
    var isSending: Bool
    var suggestions: [String] = []
    var onSend: (String) -> Void
    /// When provided, a Stop button appears while `isSending` so the user can
    /// halt a long generation and keep whatever streamed in so far.
    var onStop: (() -> Void)? = nil

    @State private var draft: String = ""

    /// Show the "Thinking…" spinner only until the first streamed token lands —
    /// once the assistant bubble has text, the growing bubble is the progress.
    private var isWaitingForFirstToken: Bool {
        isSending && (messages.last?.role != .assistant || (messages.last?.text.isEmpty ?? true))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Ask a question about \(title). The AI only knows what's in the transcript(s) here.")
                                    .foregroundStyle(.secondary)
                                if !suggestions.isEmpty {
                                    Text("Try asking").font(.caption).foregroundStyle(.secondary)
                                    ForEach(suggestions, id: \.self) { suggestion in
                                        Button {
                                            onSend(suggestion)
                                        } label: {
                                            Text(suggestion)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(isSending)
                                    }
                                }
                            }
                            .padding()
                        }
                        ForEach(messages) { message in
                            ChatBubble(message: message).id(message.id)
                        }
                        if isWaitingForFirstToken {
                            HStack { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
                                .padding(.leading, 4)
                                .id("sending-indicator")
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: messages.last?.text) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: isSending) { _, _ in
                    scrollToBottom(proxy)
                }
            }
            Divider()
            HStack(alignment: .bottom) {
                TextField("Ask about \(title)…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)
                    .disabled(isSending)
                if isSending, let onStop {
                    Button(role: .destructive, action: onStop) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop generating")
                } else {
                    Button("Send", action: send)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                }
            }
            .padding()
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation {
            if isWaitingForFirstToken {
                proxy.scrollTo("sending-indicator", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        onSend(text)
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                // The therapist's own words, shown verbatim in a trailing bubble.
                Spacer(minLength: 40)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                // The assistant answer, rendered as rich Markdown across the full
                // width (like ChatGPT/Claude) so headings, lists, and code read
                // as a document rather than a cramped bubble of raw markup.
                MarkdownMessageView(text: message.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 40)
            }
        }
    }
}
