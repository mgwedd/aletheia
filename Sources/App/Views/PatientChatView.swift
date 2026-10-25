import SwiftUI

/// The patient's cross-session chat, as multiple browsable threads (ChatGPT
/// style) instead of one running log. A sidebar lists the threads (most recent
/// first, rename/delete in the context menu); the main pane is the shared
/// `ChatPaneView` bound to the selected thread. Each thread is a `chatThread`
/// record in the SQLite store (`CommentStore`), so they persist, back up, and
/// encrypt like any other PHI, and a legacy single-thread `patient_chat.json`
/// is imported on first open (see `Store.loadChatThreads`).
///
/// This chat covers the patient: background, every session's notes and
/// comments (per-session cap), and when the history is too long to send whole,
/// session summaries plus what a search of every session points at, read
/// closer only where it looks worthwhile (see `PatientZoom`). Each session's
/// own chat lives inside that session.
struct PatientChatView: View {
    let patient: Patient
    var onDone: () -> Void

    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var recorder: SessionRecorder

    @StateObject private var chat = PatientChatModel()
    @State private var errorMessage: String?
    /// Set when a request failed because the local AI engine is down or missing
    /// its model; the alert offers a one-click fix and then re-asks the pending question.
    @State private var engineIncident: AIEngineIncident?
    @State private var pendingRetries = PendingRetries<String, () -> Void>()
    @State private var renamingThread: ChatThread?
    @State private var renameText = ""

    private var threads: [ChatThread] { chat.threads }
    private var selectedThreadID: UUID? { chat.selectedThreadID }
    private var isSending: Bool { chat.isSending }
    private var chatRunner: ChatStreamRunner { chat.runner }
    private var searchingNotice: String? { chat.searchingNotice }
    private var searchingSince: Date? { chat.searchingSince }

    //   header      title · Done
    //   sidebar     CHATS eyebrow · new chat · thread rows
    //   pane        the shared ChatPaneView, or an empty state with New Chat
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Ask About \(patient.name)")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.text.color)
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.themed)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Theme.window.color)
            .themeDivider(.bottom)

            AIEngineBanner()

            SummaryStatusRow(scheduler: integrations.digestScheduler, patientID: patient.id)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)

            HSplitView {
                threadSidebar
                    .frame(minWidth: 200, idealWidth: 230, maxWidth: 320)

                if selectedThreadID != nil {
                    ChatPaneView(
                        title: patient.name,
                        messages: $chat.messages,
                        isSending: isSending,
                        suggestions: appModel.featureRegistry.contains(id: SuggestedQuestionsFeatureModule.id) ? SuggestedQuestions.patient : [],
                        onSend: chat.send,
                        onStop: chat.stop,
                        queuedStatus: chatRunner.queuedStatus,
                        notices: chat.notices,
                        busyNotice: searchingNotice,
                        busySince: searchingSince,
                        busySteps: searchingNotice == nil ? nil : PatientAskSteps(effort: settings.patientChatEffort, layered: true).gathering,
                        onCompact: { chat.compact($0) },
                        progress: chatRunner.progress,
                        effort: $settings.patientChatEffort,
                        effortFeature: .patientChat,
                        isSessionRecording: recorder.isRecording
                    )
                    .frame(minWidth: 360)
                } else {
                    noChatSelected
                        .frame(minWidth: 360)
                }
            }
        }
        .background(Theme.window.color)
        .onAppear {
            chat.configure(appModel: appModel, integrations: integrations, settings: settings, patient: patient)
            chat.alert = { alert in
                switch alert {
                case .message(let text):
                    errorMessage = text
                case .engine(let incident, let kind, let retry):
                    _ = kind
                    pendingRetries.set(retry, for: "chat")
                    engineIncident = incident
                }
            }
            chat.reloadThreads()
            integrations.digestScheduler.patientOpened(patient)
        }
        .alert("Rename Chat", isPresented: renamingBinding) {
            TextField.patient("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renamingThread = nil }
            Button("Save") { commitRename() }
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .aiEngineAlert($engineIncident, retry: {
            for retry in pendingRetries.takeAll() { retry() }
        }, discard: {
            pendingRetries.clear()
        })
    }

    private var noChatSelected: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.muted.color)
                .accessibilityHidden(true)
            Text("No Chat Selected")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.text.color)
            Text("Start a new chat to ask about \(patient.name): background, notes and comments, session summaries, and the transcripts where a search points. Chats about a single session live inside that session.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.muted.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("New Chat") { chat.startNewThread() }
                .buttonStyle(.themePrimary)
                .padding(.top, 8)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel.color)
    }

    private var threadSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats").eyebrowStyle()
                Spacer()
                Button { chat.startNewThread() } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .buttonStyle(.themeIcon)
                .help("New chat")
                .disabled(isSending)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .themeDivider(.bottom)

            if threads.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Theme.muted.color)
                        .accessibilityHidden(true)
                    Text("No chats yet")
                        .font(Theme.Typography.control)
                        .foregroundStyle(Theme.text.color)
                    Text("Chats here cover \(patient.name) across sessions. Per-session chats live inside each session.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                        .multilineTextAlignment(.center)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(threads) { thread in
                            ThreadRow(thread: thread, isSelected: thread.id == selectedThreadID) {
                                chat.select(thread.id)
                            }
                            .contextMenu {
                                Button("Rename") { beginRename(thread) }
                                Button("Delete", role: .destructive) { chat.delete(thread) }
                            }
                        }
                    }
                    .padding(8)
                }
                // Up / Down move the selection, as in a native list.
                .focusable()
                .focusEffectDisabled()
                .onMoveCommand { direction in moveSelection(direction) }
                // Switching threads mid-generation would cross the streams.
                .disabled(isSending)
            }
        }
        .background(Theme.sidebar.color)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !threads.isEmpty else { return }
        let current = threads.firstIndex(where: { $0.id == selectedThreadID })
        switch direction {
        case .up:
            chat.select(threads[max((current ?? 1) - 1, 0)].id)
        case .down:
            chat.select(threads[min((current ?? -1) + 1, threads.count - 1)].id)
        default:
            break
        }
    }

    // MARK: - Bindings

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renamingThread != nil }, set: { if !$0 { renamingThread = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    // MARK: - Renaming

    private func beginRename(_ thread: ChatThread) {
        renamingThread = thread
        renameText = thread.title.isEmpty ? thread.displayTitle : thread.title
    }

    private func commitRename() {
        guard let thread = renamingThread else { return }
        chat.rename(thread, to: renameText)
        renamingThread = nil
    }
}

/// One thread in the sidebar: title and relative time, the accent tint when
/// selected, the hover fill under the pointer.
private struct ThreadRow: View {
    let thread: ChatThread
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    private var fill: Color {
        if isSelected { return Theme.accentTint.color }
        return isHovered ? Theme.hover.color : .clear
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.displayTitle)
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(1)
                // Redrawn every half minute so "Just now" moves on by itself.
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    Text(ChatThread.activityLabel(for: thread.updatedAt, now: timeline.date))
                        .font(Theme.Typography.caption)
                        // Muted ink has no contrast pairing on the selected tint.
                        .foregroundStyle(isSelected ? Theme.text.color : Theme.muted.color)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(fill, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
