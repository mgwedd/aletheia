import SwiftUI

/// Runs the one-click fix for an `AIEngineProblem` (open the download page,
/// launch Ollama and wait for it, or pull the model), then reports success so
/// the caller can retry the request that failed.
@MainActor
enum AIEngineRecovery {
    static func perform(_ problem: AIEngineProblem, integrations: Integrations) async throws {
        switch problem.action {
        case .getOllama:
            SystemSettingsLinks.openOllamaDownload()
        case .startOllama:
            let assistant = integrations.makeAssistant()
            try await OllamaLauncher.launchAndWaitUntilReachable { await assistant.isReachable() }
        case .downloadModel(let name):
            try await integrations.makeAssistant().pullModel(name) { _, _ in }
        case .retry:
            break
        }
    }
}

private struct AIEngineProblemAlert: ViewModifier {
    @Binding var problem: AIEngineProblem?
    let retry: () -> Void

    @EnvironmentObject private var integrations: Integrations
    @State private var working = false
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .alert(problem?.title ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                if let current = problem {
                    Button(current.actionTitle) { run(current) }
                    Button("Cancel", role: .cancel) {}
                }
            } message: {
                Text(problem?.message ?? "")
            }
            .alert("Couldn't fix the AI engine", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
            .overlay(alignment: .top) {
                if working {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Fixing the AI engine…")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.muted.color)
                    }
                    .padding(8)
                    .background(Theme.window.color, in: Capsule())
                }
            }
    }

    private func run(_ current: AIEngineProblem) {
        working = true
        Task {
            defer { working = false }
            do {
                try await AIEngineRecovery.perform(current, integrations: integrations)
                if current.retriesAfterAction { retry() }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

extension View {
    /// Shows a recovery alert for the AI engine problem, with one button that
    /// fixes it in place and then calls `retry` to re-run the failed request.
    func aiEngineProblemAlert(_ problem: Binding<AIEngineProblem?>, retry: @escaping () -> Void) -> some View {
        modifier(AIEngineProblemAlert(problem: problem, retry: retry))
    }
}
