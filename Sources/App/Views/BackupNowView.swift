import SwiftUI

/// "Back up now" in Settings > Backups: asks for a folder, then has the app
/// model write an encrypted archive of the whole data folder there. The model refuses
/// synced and network folders and only records the run when it succeeds.
struct BackupNowView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var encryption: EncryptionManager
    @State private var running = false
    @State private var message: String?

    private var available: Bool { encryption.isUnlocked && appModel.commentStore != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Back up now").eyebrowStyle()
            SettingsCaption(appModel.featureRegistry.contains(id: AtRestEncryptionFeatureModule.id)
                ? "Saves an encrypted copy of your whole data folder (database, notes, transcripts and recordings) to a folder you choose, sealed with your encryption key. Choose a folder on this Mac or an external disk that doesn't sync to the cloud. To open it on another Mac you need your recovery passphrase; Aletheia keeps a copy of the key file beside the archive."
                : "Back Up Now needs at-rest encryption, which is in developer builds only.")
            HStack(spacing: 8) {
                Button("Back Up Now…", action: choose)
                    .buttonStyle(.themed)
                    .disabled(!available || running)
                if running { ProgressView().controlSize(.small) }
                Spacer()
            }
            if !available {
                SettingsCaption(appModel.featureRegistry.contains(id: AtRestEncryptionFeatureModule.id)
                    ? "Turn on and unlock encryption to make encrypted backups."
                    : "Back Up Now is not available in this version, because it needs encryption, which released builds do not include. Back up the data folder yourself (see the Time Machine switch above) to an encrypted disk.")
            }
            if let message { SettingsCaption(message) }
        }
    }

    private func choose() {
        guard let folder = FileSaver.chooseFolder(
            prompt: "Back Up Here",
            message: "Choose a folder on this Mac or an external disk. Don't pick iCloud Drive or another synced folder."
        ) else { return }
        running = true
        message = nil
        let model = appModel
        Task {
            let outcome = await model.backUpNow(to: folder)
            await MainActor.run {
                running = false
                switch outcome {
                case .success(let archive): message = "Backed up to \(archive.lastPathComponent)."
                case .failed(let reason): message = reason
                case .notConfigured: message = "Backups aren't available right now."
                }
            }
        }
    }
}
