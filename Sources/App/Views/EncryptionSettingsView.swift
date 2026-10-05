import SwiftUI

/// Sheet for turning on Tier-2 encryption: set a recovery passphrase, with the
/// unavoidable warning that losing it loses the data (there's no backdoor).
struct EncryptionSetupSheet: View {
    @EnvironmentObject private var encryption: EncryptionManager
    @Environment(\.dismiss) private var dismiss

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

    private var canEnable: Bool { !passphrase.isEmpty && passphrase == confirm && acknowledged }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Turn On Extra Encryption").font(.title3.bold())

            Text("Encrypts your notes, transcripts, summaries, chat, patient records and recordings on disk with a passphrase — on top of the app lock. It protects your data folder even if it's on an external drive, in a backup, or in a synced folder like iCloud or Dropbox.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Label("If you forget this passphrase, your data cannot be recovered. There is no reset and no backdoor — keep it somewhere safe.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Recovery passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
            SecureField("Confirm passphrase", text: $confirm)
                .textFieldStyle(.roundedBorder)
            if !confirm.isEmpty && confirm != passphrase {
                Text("The passphrases don't match.").font(.caption).foregroundStyle(.red)
            }

            Toggle("I understand my data can't be recovered if I lose this passphrase.", isOn: $acknowledged)

            Toggle("Remember on this Mac", isOn: $rememberOnDevice)
                .help("Stores the key in this Mac's login keychain so you won't be asked for the passphrase on later launches. Leave off for maximum security.")

            if let warning {
                Text(warning).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if didEnable {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }
                    Button {
                        enable()
                    } label: {
                        if working { ProgressView().controlSize(.small) } else { Text("Turn On") }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canEnable || working)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .alert("Couldn't turn on encryption", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func enable() {
        working = true
        Task { @MainActor in
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
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.doc.fill").font(.system(size: 44)).foregroundStyle(.tint)
                Text("This data folder is encrypted").font(.title2.bold())
                Text("Enter your recovery passphrase to unlock your notes for this session.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)

                SecureField("Recovery passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit(unlock)

                Toggle("Remember on this Mac", isOn: $rememberOnDevice)
                    .toggleStyle(.checkbox)
                    .help("Stores the key in this Mac's login keychain so you won't be asked next launch. Leave off for maximum security.")

                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }

                Button("Unlock", action: unlock)
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty)

                Button("Use a different data folder…", action: chooseDifferentFolder)
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(32)
            .frame(maxWidth: 420)
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
