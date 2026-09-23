import AletheiaCore
import SwiftUI

/// Search across every patient's name, transcripts, and summaries. Picking a
/// result closes the sheet and selects that patient in the main window.
struct GlobalSearchView: View {
    @EnvironmentObject private var appModel: AppModel
    let onSelectPatient: (Patient) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PatientSearchResult] = []

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search patients, transcripts, and summaries", text: $query)
                    .textFieldStyle(.plain)
                    .onChange(of: query) { _, _ in runSearch() }
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView("Search Your Notes", systemImage: "magnifyingglass", description: Text("Find a patient by name, or any word said in a session."))
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(results) { result in
                        Section {
                            Button {
                                onSelectPatient(result.patient)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(result.patient.name).font(.headline)
                                    if result.nameMatched {
                                        Text("name match").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)

                            ForEach(result.sessionResults) { hit in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(Self.dateFormatter.string(from: hit.session.date)).font(.subheadline)
                                        Text(hit.matchedIn.label).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .padding(.leading, 8)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    private func runSearch() {
        guard let store = appModel.store else { results = []; return }
        results = store.searchAllPatients(query: query)
    }
}
