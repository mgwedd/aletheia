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
                .foregroundStyle(.secondary)
            Text("Aletheia is locked")
                .font(.title2.weight(.semibold))
            Text("Your patients' notes are protected. Unlock with Touch ID or your Mac password.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button {
                Task { await appLock.unlock() }
            } label: {
                Label("Unlock", systemImage: "touchid")
                    .frame(minWidth: 140)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)

            if let error = appLock.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
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
