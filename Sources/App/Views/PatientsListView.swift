import SwiftUI

struct PatientsListView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Binding var selectedPatient: Patient?
    @ObservedObject var search: GlobalSearchModel
    var searchFocused: FocusState<Bool>.Binding
    let onOpenSearchResult: (SearchHit) -> Void
    let onOpenSettings: () -> Void
    let onEditProfile: (Patient) -> Void

    /// The one name for adding a patient: the empty state, the footer, the shortcuts list.
    static let addPatientTitle = "Add Patient"

    @State private var showAddPatient = false
    @State private var newPatientName = ""

    private var visibleUnreadableRecords: [UnreadableEntry] {
        (appModel.unreadablePatients + appModel.unreadableDatabaseRecords)
            .filter { !settings.isDamagedRecordDismissed(id: $0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Patients")
                .eyebrowStyle()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // Not filtered by the search field: patients it matches are the first
            // group of its results (see `GlobalSearchResultsView`).
            List(appModel.patients, selection: $selectedPatient) { patient in
                PatientRow(
                    patient: patient,
                    meta: appModel.store?.fastSessionMeta(for: patient),
                    isSelected: selectedPatient?.id == patient.id
                )
                .tag(patient)
                .contextMenu {
                    Button("Edit Profile…") { onEditProfile(patient) }
                }
            }
            .listStyle(.plain)
            .overlay {
                if appModel.patients.isEmpty {
                    ContentUnavailableView {
                        Label("No Patients Yet", systemImage: "person.crop.circle.badge.plus")
                    } description: {
                        Text("Add your first patient to start recording and reviewing sessions.")
                    } actions: {
                        Button(Self.addPatientTitle) {
                            newPatientName = ""
                            showAddPatient = true
                        }
                        .buttonStyle(.themePrimary)
                        .shortcut(AppHotkey.newPatient, help: "Add a new patient")
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .background(Theme.sidebar.color)
        .navigationTitle("Patients")
        // An always-visible footer at the foot of the sidebar. The toolbar "+"
        // alone gets swept into the window's ">>" overflow when the pane is
        // narrow, so adding a patient looked impossible — this never hides.
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .dismissOnLock {
            showAddPatient = false
            newPatientName = ""   // a typed name is patient data; it does not wait behind the lock
        }
        .sheet(isPresented: $showAddPatient) {
            AddPatientSheet(name: $newPatientName) {
                if let created = appModel.addPatient(name: newPatientName) {
                    selectedPatient = created
                }
                showAddPatient = false
            } onCancel: {
                showAddPatient = false
            }
        }
        .onAppear { appModel.refreshPatients() }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlobalSearchField(model: search, isFocused: searchFocused, onOpen: onOpenSearchResult)

            if !visibleUnreadableRecords.isEmpty {
                DamagedRecordsNotice(
                    title: visibleUnreadableRecords.count == 1
                        ? "1 record couldn't be read"
                        : "\(visibleUnreadableRecords.count) records couldn't be read",
                    entries: visibleUnreadableRecords,
                    onDismiss: { entry in
                        settings.dismissDamagedRecord(id: entry.id)
                    }
                )
            }

            // In the footer, not the toolbar: toolbar items get swept into the
            // window's » overflow menu when the window is narrow.
            HStack(spacing: 8) {
                // While the list is empty its "No Patients Yet" state has the one Add Patient button.
                if !appModel.patients.isEmpty {
                    Button {
                        newPatientName = ""
                        showAddPatient = true
                    } label: {
                        Label(Self.addPatientTitle, systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.themed)
                    .shortcut(AppHotkey.newPatient, help: "Add a new patient")
                } else {
                    Spacer(minLength: 0)
                }

                // The app is in beta: a bug report is one click away.
                Button { NSWorkspace.shared.open(FeedbackLink.url(.bug)) } label: {
                    Label("Report a Bug", systemImage: FeedbackLink.bugSymbol)
                }
                .buttonStyle(.themeIcon)
                .help(FeedbackLink.bugHelp)
                .accessibilityIdentifier("sidebar-report-bug")

                Button(action: onOpenSettings) {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.themeIcon)
                .help(ShortcutGlyphs.help("Settings", ShortcutCatalog.settings))
                .accessibilityIdentifier("sidebar-settings")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebar.color)
        .themeDivider(.top)
    }
}

/// One patient in the sidebar: a monogram avatar, the name, and session count /
/// recent session date (or when they were added if no sessions exist).
private struct PatientRow: View {
    let patient: Patient
    let meta: Store.PatientSessionMeta?
    let isSelected: Bool

    private static let sessionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let addedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
        return formatter
    }()

    private var subtitleText: String {
        let count = meta?.count ?? 0
        if count > 0 {
            let sessionWord = count == 1 ? "1 session" : "\(count) sessions"
            if let newest = meta?.newestDate {
                return "\(sessionWord) · \(Self.sessionDateFormatter.string(from: newest))"
            }
            return sessionWord
        }
        return "Added \(Self.addedFormatter.string(from: patient.createdAt))"
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(PatientInitials.from(patient.name))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.chipInk.color)
                .frame(width: 30, height: 30)
                .background(Theme.chip.color, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(patient.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(1)
                Text(subtitleText)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .themeListRow(isSelected: isSelected, surface: Theme.sidebar)
    }
}

struct AddPatientSheet: View {
    @Binding var name: String
    let onAdd: () -> Void
    let onCancel: () -> Void

    /// A name is submittable only if it has something besides whitespace.
    static func canSubmit(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The single submit path for both Return in the field and the Add button.
    static func submit(name: String, onAdd: () -> Void) {
        guard canSubmit(name) else { return }
        onAdd()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Patient").font(.title2.bold())
            ThemeTextField(placeholder: "Patient name", text: $name, onSubmit: { Self.submit(name: name, onAdd: onAdd) })
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.themed)
                Button("Add") { Self.submit(name: name, onAdd: onAdd) }
                    .buttonStyle(.themePrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!Self.canSubmit(name))
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 360)
    }
}
