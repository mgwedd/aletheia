import SwiftUI

/// Sheet for turning on Tier-2 encryption, in three steps:
///
///   Passphrase ──▶ Recovery Key ──▶ Encrypt
///   choose + confirm,   24-word emergency key,       understand the risk, choose
///   strength meter      print or save as PDF,        whether to remember on this
///                       acknowledge stored safely    Mac, then encrypt
struct EncryptionSetupSheet: View {
    private enum Step: Int, CaseIterable {
        case passphrase, recoveryKey, encrypt

        var label: String {
            switch self {
            case .passphrase: return "Passphrase"
            case .recoveryKey: return "Recovery Key"
            case .encrypt: return "Encrypt"
            }
        }
    }

    @EnvironmentObject private var encryption: EncryptionManager
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .passphrase
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var recoveryKey = ""
    @State private var storedKeyAcknowledged = false
    @State private var acknowledged = false
    /// Off unless the user turns it on: a copy of the key in this Mac's keychain
    /// is an opt-in convenience.
    @State private var rememberOnDevice = EncryptionSettingsDefaults.rememberKeyOnDevice
    @State private var working = false
    @State private var didEnable = false
    @State private var warning: String?
    @State private var errorMessage: String?

    private var passphrasesMatch: Bool { !passphrase.isEmpty && passphrase == confirm }
    private var passphraseLongEnough: Bool { PassphraseStrength.meetsRequirement(passphrase) }
    private var canEnable: Bool { passphrasesMatch && passphraseLongEnough && storedKeyAcknowledged && acknowledged }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 16) {
                switch step {
                case .passphrase: passphraseStep
                case .recoveryKey: recoveryKeyStep
                case .encrypt: encryptStep
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 20)

            footer
        }
        .frame(width: 580)
        .background(Theme.panel.color)
        .tint(Theme.accent.color)
        .interactiveDismissDisabled(working)
        .onAppear {
            if recoveryKey.isEmpty {
                recoveryKey = RecoveryKey.generate()
            }
        }
        .alert("Couldn't turn on encryption", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Chrome

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
                if step == .recoveryKey {
                    Button("Back") { step = .passphrase }
                        .buttonStyle(.themed)
                        .disabled(working)
                } else if step == .encrypt {
                    Button("Back") { step = .recoveryKey }
                        .buttonStyle(.themed)
                        .disabled(working)
                }
                Button("Cancel") { dismiss() }
                    .buttonStyle(.themed)
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)

                switch step {
                case .passphrase:
                    Button("Continue") {
                        if recoveryKey.isEmpty { recoveryKey = RecoveryKey.generate() }
                        step = .recoveryKey
                    }
                    .buttonStyle(.themePrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!passphrasesMatch || !passphraseLongEnough)

                case .recoveryKey:
                    Button("Continue") { step = .encrypt }
                        .buttonStyle(.themePrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!storedKeyAcknowledged)

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

    // MARK: - Steps

    @ViewBuilder
    private var passphraseStep: some View {
        Text("Choose a passphrase. It protects the key that encrypts your notes, transcripts and recordings.")
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

        if !passphrase.isEmpty && !passphraseLongEnough {
            Text("Use at least \(PassphraseStrength.requiredLength) characters.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.recording.color)
        }

        strengthMeter

        Text("Aletheia cannot reset your passphrase. If you lose both your passphrase and your emergency recovery key, your data cannot be recovered. In the next step you'll receive a 24-word recovery key to store safely.")
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
    private var recoveryKeyStep: some View {
        Text("If you lose your passphrase, this 24-word emergency recovery key is the only way to recover your data. Save or print it and keep it in a secure offline location.")
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.muted.color)
            .fixedSize(horizontal: false, vertical: true)

        RecoveryKeyDisplay(words: RecoveryKey.words(from: recoveryKey))

        RecoveryKeyActions(key: recoveryKey, dataRoot: encryption.dataRoot, replacesPrevious: false)

        Toggle("I have saved or printed my emergency recovery key and stored it safely.", isOn: $storedKeyAcknowledged)
            .toggleStyle(.checkbox)
            .fixedSize(horizontal: false, vertical: true)
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

            Toggle("I understand my data can't be recovered if I lose my passphrase and emergency recovery key.", isOn: $acknowledged)
                .toggleStyle(.checkbox)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remember on this Mac")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.text.color)
                    Text("Keeps the key in this Mac's login keychain so you aren't asked for the passphrase on later launches. Off by default; leave it off for maximum security.")
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
            .help("Stores the key in this Mac's login keychain so you won't be asked for the passphrase on later launches. Off by default; leave it off for maximum security.")
        }
    }

    // MARK: - Actions

    private func enable() {
        working = true
        Task { @MainActor in
            // Let the progress state draw before the (synchronous) migration runs.
            await Task.yield()
            do {
                let result = try encryption.enable(passphrase: passphrase, recoveryKey: recoveryKey)
                var notes: [String] = []
                if rememberOnDevice {
                    do { try encryption.rememberOnDevice() } catch {
                        notes.append("Encryption is on, but this Mac's keychain couldn't keep the key, so you'll be asked for your passphrase on each launch. \(error.localizedDescription)")
                    }
                }
                working = false
                didEnable = true
                if !result.isComplete {
                    notes.append("Encryption is on, but \(result.failures.count) existing item(s) couldn't be converted yet. They'll be encrypted the next time they're saved.")
                }
                if notes.isEmpty {
                    dismiss()
                } else {
                    warning = notes.joined(separator: "\n\n")
                }
            } catch {
                working = false
                errorMessage = error.localizedDescription
            }
        }
    }

}

/// A labelled password field in the design's field box.
struct ThemeSecureField: View {
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

/// Clean 3-column display of 24 recovery key words.
struct RecoveryKeyDisplay: View {
    let words: [String]

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: 6) {
                    Text("\(index + 1).")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(Theme.muted.color)
                        .frame(width: 24, alignment: .trailing)
                    Text(word)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.text.color)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.field.color, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
        }
        .padding(10)
        .background(Theme.panel.color, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// Copy / Save as PDF / Print for a recovery key, with the last outcome shown
/// beside the buttons so a failed or refused save isn't silent.
struct RecoveryKeyActions: View {
    let key: String
    let dataRoot: URL?
    let replacesPrevious: Bool

    @State private var status: (text: String, ok: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Copy Words") {
                    RecoveryKeyDocument.copy(key)
                    status = ("Copied to clipboard", true)
                }
                .buttonStyle(.themed)

                Button("Save as PDF…") {
                    switch RecoveryKeyDocument.save(key: key, dataRoot: dataRoot, replacesPrevious: replacesPrevious) {
                    case .saved: status = ("Saved", true)
                    case .cancelled: break
                    case let .failed(message): status = (message, false)
                    }
                }
                .buttonStyle(.themed)

                Button("Print…") {
                    RecoveryKeyDocument.print(key: key, dataRoot: dataRoot, replacesPrevious: replacesPrevious)
                }
                .buttonStyle(.themed)
            }
            if let status {
                Text(status.text)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(status.ok ? Theme.ok.color : Theme.recording.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Sheet for creating a fresh 24-word recovery key and replacing the existing slot in Settings.
struct NewRecoveryKeySheet: View {
    @EnvironmentObject private var encryption: EncryptionManager
    @Environment(\.dismiss) private var dismiss

    @State private var newKey = RecoveryKey.generate()
    @State private var acknowledged = false
    @State private var working = false
    @State private var errorMessage: String?

    /// Folders encrypted before recovery keys existed have no slot to replace.
    private var replacesExisting: Bool { encryption.hasRecoveryKey }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 14) {
                Text(replacesExisting
                    ? "Creating a new recovery key replaces the existing one in your data folder's keystore. Any previously printed or saved recovery key will stop working immediately."
                    : "This folder doesn't have an emergency recovery key yet. Save or print this one and keep it in a secure offline location.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)

                RecoveryKeyDisplay(words: RecoveryKey.words(from: newKey))

                RecoveryKeyActions(key: newKey, dataRoot: encryption.dataRoot, replacesPrevious: replacesExisting)

                Toggle("I have saved or printed this new emergency recovery key.", isOn: $acknowledged)
                    .toggleStyle(.checkbox)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.recording.color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.recordingTint.color, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 20)

            footer
        }
        .frame(width: 580)
        .background(Theme.panel.color)
        .tint(Theme.accent.color)
    }

    private var header: some View {
        HStack {
            Text("Create New Recovery Key")
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
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.themed)
                .keyboardShortcut(.cancelAction)
                .disabled(working)

            Button {
                replaceKey()
            } label: {
                if working { ProgressView().controlSize(.small) } else { Text("Replace Recovery Key") }
            }
            .buttonStyle(.themePrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!acknowledged || working)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Theme.sidebar.color)
        .themeDivider(.top)
    }

    private func replaceKey() {
        working = true
        do {
            try encryption.replaceRecoveryKey(newKey)
            working = false
            dismiss()
        } catch {
            working = false
            errorMessage = error.localizedDescription
        }
    }
}

/// Sheet for changing the passphrase from Settings. Asks for the current
/// passphrase and a new one; only the key wrapping changes, not the files.
struct ChangePassphraseSheet: View {
    @EnvironmentObject private var encryption: EncryptionManager
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var newPassphrase = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var errorMessage: String?

    private var newLongEnough: Bool { PassphraseStrength.meetsRequirement(newPassphrase) }
    private var canChange: Bool {
        !current.isEmpty && newLongEnough && newPassphrase == confirm && !working
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Change Passphrase")
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
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 14) {
                Text("Your files aren't re-encrypted and your emergency recovery key keeps working. Only the passphrase that protects the data key changes.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)

                ThemeSecureField(label: "Current passphrase", text: $current)
                ThemeSecureField(label: "New passphrase", text: $newPassphrase)
                ThemeSecureField(label: "Confirm new passphrase", text: $confirm, submit: { if canChange { change() } })

                if !newPassphrase.isEmpty && !newLongEnough {
                    Text("Use at least \(PassphraseStrength.requiredLength) characters.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.recording.color)
                }
                if !confirm.isEmpty && confirm != newPassphrase {
                    Text("The passphrases don't match.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.recording.color)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.recording.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 20)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.themed)
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button {
                    change()
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Change Passphrase") }
                }
                .buttonStyle(.themePrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!canChange)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(Theme.sidebar.color)
            .themeDivider(.top)
        }
        .frame(width: 520)
        .background(Theme.panel.color)
        .tint(Theme.accent.color)
        .interactiveDismissDisabled(working)
    }

    private func change() {
        working = true
        errorMessage = nil
        Task { @MainActor in
            // Let the progress state draw before the key derivation runs.
            await Task.yield()
            do {
                try encryption.changePassphrase(current: current, new: newPassphrase)
                working = false
                dismiss()
            } catch {
                working = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Full-window gate shown when a folder was encrypted but its keystore file is
/// gone. Nothing is readable or writable until the file is back.
struct EncryptionKeystoreMissingView: View {
    @EnvironmentObject private var encryption: EncryptionManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel

    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.window.color).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.lock.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.recording.color)
                        .accessibilityHidden(true)
                    Text("The encryption keystore is missing")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.text.color)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(EncryptionManager.ManagerError.keystoreMissing.localizedDescription)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.recording.color)
                }
                HStack(spacing: 8) {
                    Button("Use a different data folder…") {
                        guard let url = FolderPicker.choose() else { return }
                        do {
                            try settings.setDataRoot(url)
                            appModel.rebuildStore()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .buttonStyle(.themed)
                    Spacer(minLength: 8)
                    Button("Check again") { appModel.rebuildStore() }
                        .buttonStyle(.themePrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(28)
            .frame(maxWidth: 480)
            .themeCard()
            .padding(32)
        }
    }
}
