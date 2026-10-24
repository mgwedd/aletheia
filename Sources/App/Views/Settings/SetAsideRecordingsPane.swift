import AppKit
import SwiftUI

/// Settings › Set-aside recordings: what they are, and the ways to deal with
/// them — try again (after switching data folder), put one into a session you
/// pick, or delete it. Shown only while some are set aside.
struct SetAsideRecordingsPane: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var model: SetAsideRecordings
    /// Opens the General pane, where the data folder is chosen.
    let onOpenGeneral: () -> Void

    @State private var recovering: SetAsideRecordings.Item?
    @State private var deleting: SetAsideRecordings.Item?
    @State private var message: String?

    var body: some View {
        SettingsCard {
            SettingsCardHeader(title: "What happened") {
                Chip(model.items.count == 1 ? "1 recording" : "\(model.items.count) recordings", tone: .warn)
            }
            SettingsCaption("Aletheia saves each recording into its session. These couldn't be: their session isn't in the current data folder, usually because they were recorded with another data folder open, or the session was deleted. They're kept, unencrypted, in Aletheia's private folder on this Mac until you recover or delete them.")
        }

        SettingsCard {
            SettingsCardHeader(title: "Find their session") { EmptyView() }
            SettingsCaption("If you use more than one data folder, open the one these were recorded in, then try again. Aletheia also tries again each time it opens.")
            HStack(spacing: 8) {
                Button("Try Again") { tryAgain() }
                    .buttonStyle(.themePrimary)
                Button("Choose Data Folder…", action: onOpenGeneral)
                    .buttonStyle(.themed)
            }
            if let message {
                SettingsCaption(message)
            }
        }

        SettingsRowsCard {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { SettingsHairline() }
                SettingsRow(title: title(for: item), detail: ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)) {
                    HStack(spacing: 8) {
                        Button("Recover Into…") { recovering = item }
                            .buttonStyle(.themed)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.folder]) }
                            .buttonStyle(.themed)
                        Button("Delete…") { deleting = item }
                            .buttonStyle(.themed)
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 12)
            }
        }
        .dismissOnLock { recovering = nil }
        .sheet(item: $recovering) { item in
            RecoverIntoSessionSheet(item: item) { message = $0 }
                .environmentObject(appModel)
        }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { item in
            Button("Delete Recording", role: .destructive) { delete(item) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It's removed from this Mac for good and can't be recovered.")
        }
        .onAppear { model.refresh() }
    }

    private func title(for item: SetAsideRecordings.Item) -> String {
        guard let date = item.modified else { return "Recording" }
        return "Recorded \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func tryAgain() {
        guard let store = appModel.store else {
            message = "Open a data folder first."
            return
        }
        let before = model.items.count
        let recovered = OrphanAudioSweep.retrySetAside(store: store, protector: appModel.currentProtector, audit: appModel.audit)
        model.refresh()
        if recovered > 0 { appModel.refreshPatients() }
        message = recovered > 0
            ? "Recovered \(recovered) of \(before) into their sessions."
            : "Their sessions still can't be found in this data folder."
    }

    private func delete(_ item: SetAsideRecordings.Item) {
        do {
            try model.delete(item, audit: appModel.audit)
            message = nil
        } catch {
            message = "Couldn't delete the recording: \(error.localizedDescription)"
        }
    }
}

/// Picks a patient and one of their sessions without a recording, and puts a
/// set-aside recording into it.
private struct RecoverIntoSessionSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: SetAsideRecordings.Item
    let onDone: (String) -> Void

    @State private var patientID: UUID?
    @State private var sessionID: UUID?
    @State private var error: String?

    private var patient: Patient? { appModel.patients.first { $0.id == patientID } }

    private var sessions: [SessionRecord] {
        guard let patient, let store = appModel.store else { return [] }
        return ((try? store.listSessions(for: patient)) ?? []).filter { !$0.hasRecording }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recover Into a Session")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.text.color)
            SettingsCaption("Choose the session this recording belongs to. Only sessions without a recording are listed, so nothing is replaced. It's encrypted into the session if encryption is on.")
            Picker("Patient", selection: $patientID) {
                Text("Choose…").tag(UUID?.none)
                ForEach(appModel.patients) { patient in
                    Text(patient.name).tag(Optional(patient.id))
                }
            }
            .pickerStyle(.menu)
            .onChange(of: patientID) { _, _ in sessionID = nil }
            Picker("Session", selection: $sessionID) {
                Text("Choose…").tag(UUID?.none)
                ForEach(sessions) { session in
                    Text(session.date.formatted(date: .abbreviated, time: .shortened)).tag(Optional(session.id))
                }
            }
            .pickerStyle(.menu)
            .disabled(patient == nil)
            if let error {
                Text(error)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.warn.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.themed)
                    .keyboardShortcut(.cancelAction)
                Button("Recover") { recover() }
                    .buttonStyle(.themePrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sessionID == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Theme.window.color)
    }

    private func recover() {
        guard let patient, let store = appModel.store,
              let session = sessions.first(where: { $0.id == sessionID }) else { return }
        do {
            try OrphanAudioSweep.recoverSetAside(
                item.folder, into: patient, session: session,
                store: store, protector: appModel.currentProtector, audit: appModel.audit
            )
            appModel.refreshPatients()
            onDone("Recovered into the session you chose.")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
