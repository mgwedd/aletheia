import SwiftUI

/// Full-window gate shown when an encrypted data folder hasn't been unlocked
/// this launch. Mirrors the Tier-1 `LockView` but asks for the passphrase
/// (which yields the data key) or the 24-word emergency recovery key.
struct FolderUnlockView: View {
    @EnvironmentObject private var encryption: EncryptionManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel

    @State private var isUsingRecoveryKey = false
    @State private var passphrase = ""
    @State private var recoveryKey = ""
    @State private var rememberOnDevice = false
    @State private var errorMessage: String?
    @FocusState private var recoveryKeyFocused: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.window.color).ignoresSafeArea()
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    headerView

                    if isUsingRecoveryKey {
                        recoveryKeyContent
                    } else {
                        passphraseContent
                    }

                    rememberRow

                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.recording.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.recordingTint.color, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 20)

                footerView
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .themeCard()
            .frame(maxWidth: 500)
            .padding(32)
            .tint(Theme.accent.color)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: isUsingRecoveryKey ? "key.fill" : "lock.doc.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accent.color)
                .accessibilityHidden(true)
            Text(isUsingRecoveryKey ? "Emergency Recovery Key" : "This data folder is encrypted")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.text.color)
                .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: - Content Modes

    @ViewBuilder
    private var passphraseContent: some View {
        Text("Enter your passphrase to unlock your notes for this session.")
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.muted.color)
            .fixedSize(horizontal: false, vertical: true)

        ThemeSecureField(label: "Passphrase", text: $passphrase, submit: unlockWithPassphrase)
    }

    @ViewBuilder
    private var recoveryKeyContent: some View {
        Text("Enter your 24-word emergency recovery key to unlock your encrypted data folder.")
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.muted.color)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 6) {
            Text("Emergency recovery key (24 words)").eyebrowStyle()
            TextEditor(text: $recoveryKey)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Theme.text.color)
                .focused($recoveryKeyFocused)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 88)
                .themeField(isFocused: recoveryKeyFocused)
                .accessibilityLabel("Emergency recovery key")
        }
    }

    private var rememberRow: some View {
        HStack(spacing: 12) {
            Text("Remember on this Mac")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.text.color)
            Spacer(minLength: 0)
            Toggle("Remember on this Mac", isOn: $rememberOnDevice)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent.color)
        }
        .help("Stores the key in this Mac's login keychain so you won't be asked next launch. Leave off for maximum security.")
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 8) {
            Button("Use a different data folder…", action: chooseDifferentFolder)
                .buttonStyle(.plain)
                .font(Theme.Typography.control)
                .foregroundStyle(Theme.muted.color)
            Spacer(minLength: 8)
            if isUsingRecoveryKey {
                Button("Use passphrase instead") {
                    isUsingRecoveryKey = false
                    errorMessage = nil
                }
                .buttonStyle(.themed)
                Button("Unlock", action: unlockWithRecoveryKey)
                    .buttonStyle(.themePrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button("Use recovery key…") {
                    isUsingRecoveryKey = true
                    errorMessage = nil
                }
                .buttonStyle(.themed)
                Button("Unlock", action: unlockWithPassphrase)
                    .buttonStyle(.themePrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Theme.sidebar.color)
        .themeDivider(.top)
    }

    // MARK: - Actions

    private func unlockWithPassphrase() {
        do {
            try encryption.unlock(passphrase: passphrase)
            if rememberOnDevice { try? encryption.rememberOnDevice() }
            passphrase = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unlockWithRecoveryKey() {
        do {
            try encryption.unlock(recoveryKey: recoveryKey)
            if rememberOnDevice { try? encryption.rememberOnDevice() }
            recoveryKey = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseDifferentFolder() {
        guard let url = FolderPicker.choose() else { return }
        do {
            try settings.setDataRoot(url)
            appModel.rebuildStore()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Backwards compatibility alias for the unlock view overlay.
typealias EncryptionUnlockView = FolderUnlockView
