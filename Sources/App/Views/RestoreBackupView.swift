import SwiftUI

/// "Restore from backup" in Settings > Backups: pick a backup file, enter the
/// passphrase, pick an empty folder to restore into. The folder in use is never
/// touched; the app opens the restored copy when it succeeds.
struct RestoreBackupView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var archive: URL?
    @State private var passphrase = ""
    @State private var running = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Restore from backup").eyebrowStyle()
            SettingsCaption("Restores a backup made with Back Up Now into a new, empty folder, then opens it. Your current data folder isn't changed or overwritten. You need the passphrase you used when you turned on encryption, and the key file kept beside the backup.")
            HStack(spacing: 8) {
                Button("Choose Backup…", action: chooseArchive)
                    .buttonStyle(.themed)
                    .disabled(running)
                if let archive { SettingsCaption(archive.lastPathComponent) }
                Spacer()
            }
            if archive != nil {
                ThemeSecureField(label: "Passphrase", text: $passphrase)
                HStack(spacing: 8) {
                    Button("Restore Into Empty Folder…", action: restore)
                        .buttonStyle(.themed)
                        .disabled(passphrase.isEmpty || running)
                    if running { ProgressView().controlSize(.small) }
                    Spacer()
                }
            }
            if let message { SettingsCaption(message) }
        }
    }

    private func chooseArchive() {
        guard let url = FileSaver.chooseFile(
            prompt: "Choose Backup",
            message: "Choose a backup file made with Back Up Now.",
            fileExtension: EncryptedBackupArchive.fileExtension
        ) else { return }
        archive = url
        message = nil
    }

    private func restore() {
        guard let archive,
              let folder = FileSaver.chooseFolder(
                prompt: "Restore Here",
                message: "Choose a new or empty folder on this Mac or an external disk. Don't pick iCloud Drive or another synced folder."
              ) else { return }
        running = true
        message = nil
        let model = appModel
        let secret = passphrase
        Task {
            let outcome = await model.restoreBackup(archive: archive, passphrase: secret, into: folder)
            await MainActor.run {
                running = false
                switch outcome {
                case .success(let url):
                    passphrase = ""
                    message = "Restored to \(url.lastPathComponent) and opened it."
                case .failed(let reason): message = reason
                case .notConfigured: message = "Restoring isn't available right now."
                }
            }
        }
    }
}
