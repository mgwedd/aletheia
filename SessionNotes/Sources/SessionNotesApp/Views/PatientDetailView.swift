import SwiftUI

struct PatientDetailView: View {
    let patient: Patient

    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations
    @State private var sessions: [SessionRecord] = []
    @State private var selectedSession: SessionRecord?
    @State private var notes: String = ""
    @State private var clinicalHistory: String = ""
    @State private var medications: [Medication] = []
    @State private var showPatientChat = false
    @State private var errorMessage: String?
    /// Clinical background (history + medications) is important context, so it
    /// starts open. Controlled (vs. a bare DisclosureGroup) so the chevron
    /// reliably toggles it.
    @State private var showBackground = true

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 100, maxHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    .onChange(of: notes) { _, newValue in
                        // Skip the onAppear sync (notes = patient.notes)
                        // firing this too — only persist actual edits.
                        guard newValue != patient.notes else { return }
                        var updated = patient
                        updated.notes = newValue
                        appModel.savePatientNotes(updated)
                    }

                backgroundSection

                HStack {
                    Button {
                        showPatientChat = true
                    } label: {
                        Label("Ask About All Sessions", systemImage: "bubble.left.and.bubble.right")
                    }
                    .disabled(sessions.isEmpty)
                    Spacer()
                    Button {
                        exportHistory()
                    } label: {
                        Label("Export History", systemImage: "square.and.arrow.up")
                    }
                    .disabled(sessions.isEmpty)
                }

                Divider()

                HStack {
                    Text("Sessions").font(.headline)
                    Spacer()
                    Button {
                        newSession()
                    } label: {
                        Label("New Session", systemImage: "plus")
                    }
                }

                List(sessions, selection: $selectedSession) { session in
                    SessionRow(session: session).tag(session)
                }
                .listStyle(.inset)
                .overlay {
                    if sessions.isEmpty {
                        ContentUnavailableView {
                            Label("No Sessions Yet", systemImage: "waveform")
                        } description: {
                            Text("Start a session to record, transcribe, and summarize it.")
                        } actions: {
                            Button("New Session") { newSession() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .padding()
            .frame(minWidth: 320)

            if let selectedSession {
                SessionDetailView(patient: patient, session: selectedSession, onSessionUpdated: refresh)
                    .id(selectedSession.id)
            } else {
                ContentUnavailableView(
                    "Select a Session",
                    systemImage: "waveform",
                    description: Text("Choose a session on the left, or start a new one.")
                )
            }
        }
        .navigationTitle(patient.name)
        .onAppear {
            notes = patient.notes
            clinicalHistory = patient.clinicalHistory
            medications = patient.medications
            refresh()
        }
        .sheet(isPresented: $showPatientChat) {
            PatientChatSheet(patient: patient)
                .environmentObject(appModel)
                .environmentObject(integrations)
                .frame(minWidth: 560, minHeight: 500)
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    /// A collapsible patient background: a free-text clinical-history TL;DR and a
    /// medications (name | dose) table. Both are saved to the patient and fed to
    /// the AI's patient context so it can weigh them when relevant.
    private var backgroundSection: some View {
        DisclosureGroup("Background", isExpanded: $showBackground) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Clinical history").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $clinicalHistory)
                    .font(.body)
                    .frame(minHeight: 70, maxHeight: 130)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    .onChange(of: clinicalHistory) { _, v in
                        guard v != patient.clinicalHistory else { return }
                        saveBackground()
                    }

                HStack {
                    Text("Medications").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { medications.append(Medication()) } label: {
                        Label("Add Medication", systemImage: "plus")
                    }
                    .labelStyle(.iconOnly)
                    .help("Add a medication")
                }

                if medications.isEmpty {
                    Text("None recorded.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach($medications) { $med in
                        HStack(spacing: 6) {
                            TextField("Medication", text: $med.name)
                            TextField("Dose", text: $med.dose).frame(width: 110)
                            Button(role: .destructive) {
                                medications.removeAll { $0.id == med.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                    }
                }

                Text("Saved with the patient and shared with the AI's patient context.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            .onChange(of: medications) { _, v in
                guard v != patient.medications else { return }
                saveBackground()
            }
        }
    }

    private func saveBackground() {
        var updated = patient
        updated.clinicalHistory = clinicalHistory
        updated.medications = medications
        appModel.savePatientNotes(updated)
    }

    private func refresh() {
        guard let store = appModel.store else { return }
        do {
            sessions = try store.listSessions(for: patient)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func newSession() {
        guard let store = appModel.store else { return }
        do {
            let session = try store.createSession(for: patient)
            refresh()
            selectedSession = session
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportHistory() {
        guard let store = appModel.store else { return }
        let markdown = store.exportPatientHistoryMarkdown(patient: patient)
        let name = FileSaver.fileName(patient.name, "Session History") + ".md"
        FileSaver.saveText(markdown, suggestedName: name)
    }
}

private struct SessionRow: View {
    let session: SessionRecord

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(Self.formatter.string(from: session.date)).font(.body)
                HStack(spacing: 6) {
                    if session.hasRecording { Label("Recording", systemImage: "waveform").labelStyle(.iconOnly) }
                    if session.hasTranscript { Label("Transcript", systemImage: "text.alignleft").labelStyle(.iconOnly) }
                    if session.hasSummary { Label("Summary", systemImage: "doc.text").labelStyle(.iconOnly) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PatientChatSheet: View {
    let patient: Patient
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var integrations: Integrations
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PatientChatView(patient: patient) { dismiss() }
            .environmentObject(appModel)
            .environmentObject(integrations)
    }
}
