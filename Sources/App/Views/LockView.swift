import SwiftUI

/// The full-window cover shown while the app is locked (Tier-1 protection).
/// It is only a lock symbol: the system biometric / password sheet opens
/// automatically and is the one place to authenticate. If the sheet is
/// cancelled, the symbol itself is the way back in.
struct LockView: View {
    @EnvironmentObject private var appLock: AppLock

    var body: some View {
        VStack(spacing: 16) {
            Button {
                appLock.requestUnlock()
            } label: {
                Label(LockScreenCopy.unlockLabel, systemImage: "lock")
            }
            .buttonStyle(.themeLockSymbol)
            .keyboardShortcut(.defaultAction)
            .focusable()
            .help(LockScreenCopy.unlockLabel)
            .accessibilityLabel(LockScreenCopy.unlockLabel)

            // Only a genuine failure (not a cancel) is worth a word.
            if let error = appLock.lastError {
                Text(error)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.recording.color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.recordingTint.color, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque, not translucent: nothing behind the cover may show through.
        .background(Theme.sidebar.color)
        // Not while backgrounded: AppLock prompts when the app becomes active.
        .task { await appLock.unlockIfActive() }
    }
}
