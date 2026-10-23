import SwiftUI

struct DataFolderMoveView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var original: URL?
    @State private var moved = false
    @State private var errorMessage: String?
    @State private var confirmDelete = false
    @State private var alternateDestination: URL?
    @State private var holdsOriginalAccess = false
    @State private var isMoving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Move data to this Mac")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.text.color)
            if moved {
                Text("The copy was verified and Aletheia now uses the standard local folder. Copies already synced to a cloud service must also be removed there and on other devices.")
                HStack {
                    Button("Keep original for now") { finish() }.buttonStyle(.themed)
                    Button("Delete original folder…") { confirmDelete = true }.buttonStyle(.themePrimary)
                        .disabled(!holdsOriginalAccess)
                }
            } else {
                Text("The selected data folder syncs or is stored outside this Mac. Aletheia will copy it to a local folder and verify each file before using the copy. The original stays in place until you choose to delete it.")
                Text(settings.dataRootURL?.path ?? "")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                Text("Destination: \(destination.path)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                Button("Choose another local destination…") {
                    alternateDestination = FolderPicker.choose()
                    errorMessage = nil
                }
                .buttonStyle(.themed)
                .disabled(isMoving)
                HStack {
                    Button("Copy and verify data") { move() }
                        .buttonStyle(.themePrimary)
                        .disabled(isMoving)
                    if isMoving { ProgressView().controlSize(.small) }
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(Theme.accent.color)
            }
        }
        .font(Theme.Typography.body)
        .foregroundStyle(Theme.text.color)
        .padding(32)
        .frame(width: 540)
        .background(Theme.panel.color)
        .interactiveDismissDisabled(!moved)
        .confirmationDialog("Delete the original folder?", isPresented: $confirmDelete) {
            Button("Delete original folder", role: .destructive) { deleteOriginal() }
            Button("Keep original", role: .cancel) { finish() }
        } message: {
            Text("Only the original folder on this Mac will be deleted. Remove any copies already synced to the cloud and other devices separately.")
        }
    }

    private var destination: URL {
        alternateDestination.map(DataFolderMove.destination(inChosenFolder:)) ?? AppSettings.standardDataRoot
    }

    private func move() {
        guard let source = settings.dataRootURL else { return }
        let target = self.destination
        let usesStandard = alternateDestination == nil
        holdsOriginalAccess = source.startAccessingSecurityScopedResource()
        isMoving = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try DataFolderMove.copyAndRebind(source: source, destination: target) { _ in
                    try DispatchQueue.main.sync {
                        if usesStandard {
                            try settings.useStandardDataRoot()
                        } else {
                            try settings.setDataRoot(target)
                        }
                    }
                }
                DispatchQueue.main.async {
                    original = source
                    moved = true
                    isMoving = false
                    appModel.dataFolderMoved()
                }
            } catch {
                DispatchQueue.main.async {
                    if holdsOriginalAccess { source.stopAccessingSecurityScopedResource() }
                    holdsOriginalAccess = false
                    isMoving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func deleteOriginal() {
        guard let original else { return }
        do {
            try FileManager.default.removeItem(at: original)
            finish()
        } catch {
            errorMessage = "The local copy is ready, but the original could not be deleted: \(error.localizedDescription)"
        }
    }

    private func finish() {
        if holdsOriginalAccess { original?.stopAccessingSecurityScopedResource() }
        holdsOriginalAccess = false
        dismiss()
    }
}
