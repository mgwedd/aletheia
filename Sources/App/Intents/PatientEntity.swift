import AletheiaCore
import AppIntents

/// A patient exposed to Shortcuts/Siri so intents can take "for [patient]".
struct PatientEntity: AppEntity, Identifiable {
    let id: UUID
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Patient")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var defaultQuery = PatientEntityQuery()
}

struct PatientEntityQuery: EntityQuery {
    func entities(for identifiers: [PatientEntity.ID]) async throws -> [PatientEntity] {
        allPatients().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [PatientEntity] {
        allPatients()
    }

    private func allPatients() -> [PatientEntity] {
        guard let store = SessionQueries.currentStore() else { return [] }
        let patients = (try? store.listPatients()) ?? []
        return patients.map { PatientEntity(id: $0.id, name: $0.name) }
    }
}
