import SwiftUI
import AppKit

/// The side effects a recovery can perform, as closures so the routing from a
/// problem to its fix is unit-tested with fakes.
struct AIEngineActions {
    var downloadBuiltInModel: (_ onProgress: @escaping (Double, String) -> Void) async throws -> Void = { _ in }

    @MainActor
    static func live(integrations: Integrations) -> AIEngineActions {
        AIEngineActions(
            downloadBuiltInModel: { onProgress in
                try await integrations.downloadBuiltInModel { progress in
                    onProgress(progress, LlamaModelDownloader.shared.statusText)
                }
            }
        )
    }
}

/// Runs the one-click fix for an `AIEngineProblem`.
enum AIEngineRecovery {
    static func perform(
        _ problem: AIEngineProblem,
        actions: AIEngineActions,
        onProgress: @escaping (Double, String) -> Void = { _, _ in }
    ) async throws {
        switch problem.action {
        case .downloadBuiltInModel: try await actions.downloadBuiltInModel(onProgress)
        case .retry: break
        }
    }
}

/// Drives one recovery at a time and publishes what the progress UI shows.
@MainActor
final class AIEngineRecoveryController: ObservableObject {
    typealias Perform = @MainActor (_ problem: AIEngineProblem, _ onProgress: @escaping (Double, String) -> Void) async throws -> Void

    @Published private(set) var isWorking = false
    /// 0...1 while a model downloads; nil when the work has no measurable progress.
    @Published private(set) var progress: Double?
    @Published private(set) var status = ""
    @Published var failure: String?

    /// Returns true when the fix succeeded. A second call while one is running
    /// does nothing and returns false.
    func run(_ problem: AIEngineProblem, perform: Perform) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        failure = nil
        progress = nil
        status = Self.startingStatus(for: problem)
        switch problem.action {
        case .downloadBuiltInModel: progress = 0
        default: break
        }
        defer { isWorking = false }
        do {
            try await perform(problem) { [weak self] fraction, text in
                Task { @MainActor in self?.report(fraction: fraction, text: text) }
            }
            return true
        } catch {
            failure = error.localizedDescription
            return false
        }
    }

    func report(fraction: Double, text: String) {
        progress = min(max(fraction, 0), 1)
        if !text.isEmpty { status = text }
    }

    static func startingStatus(for problem: AIEngineProblem) -> String {
        switch problem.action {
        case .downloadBuiltInModel: return "Downloading the AI model…"
        case .retry: return "Trying again…"
        }
    }
}

/// Progress for a recovery in flight: a bar for a download, a spinner otherwise.
struct AIEngineProgressView: View {
    @ObservedObject var controller: AIEngineRecoveryController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fraction = controller.progress {
                ThemeProgressBar(value: fraction)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(controller.status)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private func copyDetails(_ incident: AIEngineIncident, integrations: Integrations) {
    let text = AIEngineSupportReport.text(
        incident: incident,
        appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        macOS: ProcessInfo.processInfo.operatingSystemVersionString,
        backend: integrations.effectiveAssistantBackend.displayName,
        model: integrations.activeModelName
    )
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private struct AIEngineAlert: ViewModifier {
    @Binding var incident: AIEngineIncident?
    let retry: () -> Void
    let discard: () -> Void

    @EnvironmentObject private var integrations: Integrations
    @StateObject private var controller = AIEngineRecoveryController()

    func body(content: Content) -> some View {
        content
            .alert(incident?.problem.title ?? "", isPresented: Binding(get: { incident != nil }, set: { if !$0 { incident = nil } })) {
                if let current = incident {
                    Button(current.problem.actionTitle) { run(current.problem) }
                    Button("Copy Details") { copyDetails(current, integrations: integrations) }
                    Button("Cancel", role: .cancel) { discard() }
                }
            } message: {
                Text(incident?.problem.message ?? "")
            }
            .alert("Couldn't fix the AI engine", isPresented: Binding(get: { controller.failure != nil }, set: { if !$0 { controller.failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(controller.failure ?? "")
            }
            .overlay {
                if controller.isWorking {
                    ZStack {
                        Theme.text.color.opacity(0.12)
                        AIEngineProgressView(controller: controller)
                            .padding(16)
                            .frame(width: 320)
                            .background(Theme.window.color, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    }
                }
            }
    }

    private func run(_ problem: AIEngineProblem) {
        Task {
            let fixed = await controller.run(problem) { problem, onProgress in
                try await AIEngineRecovery.perform(problem, actions: .live(integrations: integrations), onProgress: onProgress)
            }
            if fixed, problem.retriesAfterAction {
                retry()
            } else {
                // Nothing will re-run the failed request (the fix failed), so
                // don't keep it for later.
                discard()
            }
        }
    }
}

extension View {
    /// Shows a recovery alert for the AI engine problem, with one button that
    /// fixes it in place (with progress), a Copy Details button for support, and
    /// a `retry` of the failed requests after a successful fix. `discard` runs
    /// when no retry will happen (Cancel or a failed fix), so the caller can drop what it was holding.
    func aiEngineAlert(_ incident: Binding<AIEngineIncident?>, retry: @escaping () -> Void, discard: @escaping () -> Void) -> some View {
        modifier(AIEngineAlert(incident: incident, retry: retry, discard: discard))
    }
}

/// A passive banner shown where an AI feature lives when the engine isn't ready,
/// so the first sign isn't a failed request. Checks when it appears and each
/// time the app becomes active; shows nothing while the engine is fine.
///
/// No "Copy Details": nothing has failed yet, so there is no underlying error
/// to copy, only the problem's own name. The alert for a real failed request
/// keeps it.
struct AIEngineBanner: View {
    @EnvironmentObject private var integrations: Integrations
    @StateObject private var controller = AIEngineRecoveryController()
    @State private var problem: AIEngineProblem?

    var body: some View {
        // The zero-height clear view keeps the modifiers below alive while no
        // banner is showing (an empty `if` would never fire `.task`).
        ZStack(alignment: .top) {
            Color.clear.frame(height: 0)
            if let problem {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Theme.warn.color)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(problem.title)
                                .font(Theme.Typography.headline)
                                .foregroundStyle(Theme.text.color)
                            Text(problem.message)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.muted.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button(problem.actionTitle) { fix(problem) }
                            .buttonStyle(.themePrimary)
                            .controlSize(.small)
                            .disabled(controller.isWorking)
                    }
                    if controller.isWorking {
                        AIEngineProgressView(controller: controller)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel.color)
                .themeDivider(.bottom)
            }
        }
        .task { await check() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await check() }
        }
        .alert("Couldn't fix the AI engine", isPresented: Binding(get: { controller.failure != nil }, set: { if !$0 { controller.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.failure ?? "")
        }
    }

    private func check() async {
        guard !controller.isWorking else { return }
        problem = await AIEngineHealth.problem(integrations: integrations)
    }

    private func fix(_ current: AIEngineProblem) {
        Task {
            _ = await controller.run(current) { problem, onProgress in
                try await AIEngineRecovery.perform(problem, actions: .live(integrations: integrations), onProgress: onProgress)
            }
            await check()
        }
    }
}

/// Reads the engine's state the way the setup checklist does, so the banner and
/// the checklist agree.
@MainActor
enum AIEngineHealth {
    static func problem(integrations: Integrations) async -> AIEngineProblem? {
        let modelURL = integrations.llamaModelURL
        return AIEngineProbe(
            isBuiltInBackend: integrations.effectiveAssistantBackend == .localLlama,
            builtInModelPresent: { FileManager.default.fileExists(atPath: modelURL.path) }
        ).problem()
    }
}
