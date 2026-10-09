import SwiftUI

/// The full-window cover shown while the app is locked (Tier-1 protection).
/// It hides all PHI behind the user's Touch ID / password and prompts
/// automatically on appear, so unlocking is usually a single glance.
struct LockView: View {
    @EnvironmentObject private var appLock: AppLock

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(Theme.muted.color)
            Text("Aletheia is locked")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.text.color)
            Text("Your patients' notes are protected. Unlock with Touch ID or your Mac password.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.muted.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button {
                Task { await appLock.unlock() }
            } label: {
                Label("Unlock", systemImage: "touchid")
                    .frame(minWidth: 140)
            }
            .buttonStyle(.themePrimary)
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)

            if let error = appLock.lastError {
                Text(error)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.recording.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .task { await appLock.unlock() }
    }
}
