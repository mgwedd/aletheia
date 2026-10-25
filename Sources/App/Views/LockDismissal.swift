import SwiftUI

private struct LockGenerationKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// How many times the app lock has engaged. Set by the lock cover of each
    /// window, so every sheet presented from that window sees it.
    var lockGeneration: Int {
        get { self[LockGenerationKey.self] }
        set { self[LockGenerationKey.self] = newValue }
    }
}

private struct DismissOnLock: ViewModifier {
    @Environment(\.lockGeneration) private var generation
    @State private var shownGeneration: Int?
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { shownGeneration = generation }
            .onChange(of: generation) { _, current in
                guard let shown = shownGeneration,
                      LockSheetPolicy.shouldDismiss(presentedGeneration: shown, currentGeneration: current)
                else { return }
                shownGeneration = current
                action()
            }
    }
}

extension View {
    /// Runs `action` when the app locks, for the view that owns sheets: it resets
    /// the flags that present them, so they close and do not return on unlock.
    func dismissOnLock(_ action: @escaping () -> Void) -> some View {
        modifier(DismissOnLock(action: action))
    }
}
