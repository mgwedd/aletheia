import SwiftUI

/// Sheet for turning on Tier-2 encryption, in two steps:
///
///   Passphrase ──▶ Encrypt
///   choose + confirm,   understand the risk, choose whether to remember it
///   strength meter      on this Mac, then encrypt (progress, then done)
///
/// There is no recovery key: the passphrase is the only way back in, and the
/// sheet says so plainly.
struct EncryptionSetupSheet: View {
    private enum Step: Int, CaseIterable {
        case passphrase, encrypt

        var label: String {
            switch self {
            case .passphrase: return "Passphrase"
            case .encrypt: return "Encrypt"
            }
        }
    }

    @EnvironmentObject private var encryption: EncryptionManager
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .passphrase
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var acknowledged = false
    /// Default on: store the key in this Mac's keychain so, after this one-time
    /// setup, encryption is transparent on every later launch. The passphrase
    /// stays the recovery path if the keychain is ever lost.
    @State private var rememberOnDevice = true
    @State private var working = false
    @State private var didEnable = false
    @State private var warning: String?
    @State private var errorMessage: String?

    private var passphrasesMatch: Bool { !passphrase.isEmpty && passphrase == confirm }
    private var canEnable: Bool { passphrasesMatch && acknowledged }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 16) {
                switch step {
                case .passphrase: passphraseStep
                case .encrypt: encryptStep
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 20)

            footer
        }
        .frame(width: 560)
        .background(Theme.panel.color)
        .tint(Theme.accent.color)
        .interactiveDismissDisabled(working)
        .alert("Couldn't turn on encryption", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(didEnable ? "Encryption is on" : "Turn on encryption")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.text.color)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { dismiss() } label: {
                    Label("Close", systemImage: "xmark")
                }
                .buttonStyle(.themeIcon)
                .keyboardShortcut(.cancelAction)
                .disabled(working)
                .help("Close")
            }
            stepIndicator
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }

    /// One accent bar and label per step; completed and current steps are lit.
    private var stepIndicator: some View {
        let total = Step.allCases.count
        let reached = didEnable ? total : step.rawValue + 1
        return HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { item in
                let lit = item.rawValue < reached
                VStack(alignment: .leading, spacing: 6) {
                    Capsule()
                        .fill(lit ? Theme.accent.color : Theme.chip.color)
                        .frame(height: 4)
                    Text(item.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(lit ? Theme.text.color : Theme.muted.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeOut(duration: 0.15), value: reached)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(reached) of \(total): \(Step.allCases[reached - 1].label)")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            if didEnable {
                Button("Done") { dismiss() }
                    .buttonStyle(.themePrimary)
                    .keyboardShortcut(.defaultAction)
            } else {
                if step == .encrypt {
                    Button("Back") { step = .passphrase }
                        .buttonStyle(.themed)
                        .disabled(working)
                }
                Button("Cancel") { dismiss() }
                    .buttonStyle(.themed)
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                switch step {
                case .passphrase:
                    Button("Continue") { step = .encrypt }
                        .buttonStyle(.themePrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!passphrasesMatch)
                case .encrypt:
                    Button {
                        enable()
                    } label: {
                        if working { ProgressView().controlSize(.small) } else { Text("Encrypt my data") }
                    }
                    .buttonStyle(.themePrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canEnable || working)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Theme.sidebar.color)
        .themeDivider(.top)
    }

    // MARK: Steps

    @ViewBuilder
    private var passphraseStep: some View {
        Text("Choose a passphrase. It protects the key that encrypts your notes, transcripts and recordings on this Mac.")
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.muted.color)
            .fixedSize(horizontal: false, vertical: true)

        ThemeSecureField(label: "Passphrase", text: $passphrase)
        ThemeSecureField(label: "Confirm passphrase", text: $confirm)
        if !confirm.isEmpty && confirm != passphrase {
            Text("The passphrases don't match.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.recording.color)
        }

        strengthMeter

        Text("Aletheia cannot reset this passphrase. If you lose it, your data cannot be recovered. There is no reset, no backdoor and no recovery key, so keep it somewhere safe.")
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.text.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themeBanner(.warn)
    }

    private var strengthMeter: some View {
        let result = PassphraseStrength.evaluate(passphrase)
        let tint: Color
        let tone: Chip.Tone
        let word: String
        switch result.strength {
        case .weak:
            tint = Theme.recording.color
            tone = .recording
            word = "Weak"
        case .fair:
            tint = Theme.warn.color
            tone = .warn
            word = "Fair"
        case .strong:
            tint = Theme.ok.color
            tone = .ok
            word = "Strong"
        }
        return HStack(spacing: 10) {
            ThemeProgressBar(value: result.fraction, tint: tint)
            Chip(word, tone: tone)
                .opacity(passphrase.isEmpty ? 0 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Passphrase strength")
        .accessibilityValue(passphrase.isEmpty ? "Not entered" : word)
    }

    @ViewBuilder
    private var encryptStep: some View {
        if working {
            Text("Encrypting existing files in your data folder. Keep Aletheia open until this finishes.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
            ProgressView()
                .progressViewStyle(.linear)
                .tint(Theme.accent.color)
                .accessibilityLabel("Encrypting")
        } else if didEnable {
            if let warning {
                Text(warning)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .themeBanner(.warn)
            }
        } else {
            Text("Encrypts your notes, transcripts, summaries, chat, patient records and recordings on disk with a passphrase, on top of the app lock. It protects your data folder even if it's on an external drive, in a backup, or in a synced folder like iCloud or Dropbox.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("I understand my data can't be recovered if I lose this passphrase.", isOn: $acknowledged)
                .toggleStyle(.checkbox)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remember on this Mac")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.text.color)
                    Text("Keeps the key in this Mac's login keychain so you aren't asked for the passphrase on later launches. Turn off for maximum security.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("Remember on this Mac", isOn: $rememberOnDevice)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.accent.color)
            }
            .help("Stores the key in this Mac's login keychain so you won't be asked for the passphrase on later launches. Leave off for maximum security.")
        }
    }

    // MARK: Action

    private func enable() {
        working = true
        Task { @MainActor in
            // Let the progress state draw before the (synchronous) migration runs.
            await Task.yield()
            do {
                let result = try encryption.enable(passphrase: passphrase)
                if rememberOnDevice { try? encryption.rememberOnDevice() }
                working = false
                didEnable = true
                if !result.isComplete {
                    warning = "Encryption is on, but \(result.failures.count) existing item(s) couldn't be converted yet. They'll be encrypted the next time they're saved."
                } else {
                    dismiss()
                }
            } catch {
                working = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A labelled password field in the design's field box.
private struct ThemeSecureField: View {
    let label: String
    @Binding var text: String
    var submit: (() -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).eyebrowStyle()
            SecureField("", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.text.color)
                .focused($focused)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .themeField(isFocused: focused)
                .accessibilityLabel(label)
                .onSubmit { submit?() }
        }
    }
}

/// Full-window gate shown when an encrypted data folder hasn't been unlocked
/// this launch. Mirrors the Tier-1 `LockView` but asks for the recovery
/// passphrase (which yields the data key) rather than Touch ID.
struct EncryptionUnlockView: View {
    @EnvironmentObject private var encryption: EncryptionManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel

    @State private var passphrase = ""
    @State private var rememberOnDevice = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.window.color).ignoresSafeArea()
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.doc.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.accent.color)
                            .accessibilityHidden(true)
                        Text("This data folder is encrypted")
                            .font(Theme.Typography.title)
                            .foregroundStyle(Theme.text.color)
                            .accessibilityAddTraits(.isHeader)
                    }

                    Text("Enter your recovery passphrase to unlock your notes for this session.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.muted.color)
                        .fixedSize(horizontal: false, vertical: true)

                    ThemeSecureField(label: "Recovery passphrase", text: $passphrase, submit: unlock)

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

                HStack(spacing: 8) {
                    Button("Use a different data folder…", action: chooseDifferentFolder)
                        .buttonStyle(.plain)
                        .font(Theme.Typography.control)
                        .foregroundStyle(Theme.muted.color)
                    Spacer(minLength: 8)
                    Button("Unlock", action: unlock)
                        .buttonStyle(.themePrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(passphrase.isEmpty)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(Theme.sidebar.color)
                .themeDivider(.top)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .themeCard()
            .frame(maxWidth: 480)
            .padding(32)
            .tint(Theme.accent.color)
        }
    }

    private func unlock() {
        do {
            try encryption.unlock(passphrase: passphrase)
            if rememberOnDevice { try? encryption.rememberOnDevice() }
            passphrase = ""
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
