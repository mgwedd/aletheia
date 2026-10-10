import AppKit
import LocalAuthentication
import SwiftUI

/// The full-window cover shown while the app is locked (Tier-1 protection).
/// It hides all PHI behind the user's Touch ID / password and prompts
/// automatically on appear, so unlocking is usually a single glance.
struct LockView: View {
    @EnvironmentObject private var appLock: AppLock

    /// What this Mac can unlock with, so the button names the real method.
    private struct UnlockMethod {
        var title = "Unlock"
        var symbol = "lock.open"

        /// Touch ID / Face ID when the Mac has enrolled biometrics, else a plain
        /// "Unlock" (the system sheet then asks for the Mac password).
        static func current() -> UnlockMethod {
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
                return UnlockMethod()
            }
            switch context.biometryType {
            case .touchID: return UnlockMethod(title: "Unlock with Touch ID", symbol: "touchid")
            case .faceID: return UnlockMethod(title: "Unlock with Face ID", symbol: "faceid")
            default: return UnlockMethod()
            }
        }
    }

    @State private var method = UnlockMethod()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 22) {
                ZStack {
                    Circle().fill(Theme.accentTint.color)
                    Image(systemName: "lock")
                        .font(.system(size: 32, weight: .regular))
                        .foregroundStyle(Theme.accent.color)
                }
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Aletheia is locked")
                        .font(Theme.Typography.display)
                        .foregroundStyle(Theme.text.color)
                        .accessibilityAddTraits(.isHeader)
                    Text("No client names or notes are shown while it is locked. Unlock with Touch ID or your Mac password.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.muted.color)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 380)
                }

                Button {
                    Task { await appLock.unlock() }
                } label: {
                    Label(method.title, systemImage: method.symbol)
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
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.recordingTint.color, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        .frame(maxWidth: 380)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 16) {
                Text("Each unlock is recorded in the audit log, without any client content.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Quit Aletheia") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.muted.color)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .themeDivider(.top)
        }
        // Opaque, not translucent: nothing behind the cover may show through.
        .background(Theme.sidebar.color)
        .onAppear { method = UnlockMethod.current() }
        .task { await appLock.unlock() }
    }
}
