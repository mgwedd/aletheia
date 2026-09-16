import SwiftUI

/// Reusable chat UI shared by the per-session and cross-patient chat
/// features. Deliberately dumb: the caller owns the message list and
/// decides what "send" means (which transcript/context to include).
struct ChatPaneView: View {
    let title: String
    @Binding var messages: [ChatMessage]
    var isSending: Bool
    var onSend: (String) -> Void

    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            Text("Ask a question about \(title). The AI only knows what's in the transcript(s) here.")
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                        ForEach(messages) { message in
                            ChatBubble(message: message).id(message.id)
                        }
                        if isSending {
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
                Button("Send", action: send)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
            .padding()
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation {
            if isSending {
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
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.text)
                .textSelection(.enabled)
                .padding(10)
                .background(message.role == .user ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}
