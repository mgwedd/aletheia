// Part of the `.dev`-tier App Intents surface — compiled out of production and
// preview builds. See AletheiaIntents.swift / AppIntentsFeatureModule.
#if ALETHEIA_DEV
import AppIntents

/// A patient exposed to Shortcuts/Siri so intents can take "for [patient]".
struct PatientEntity: AppEntity, Identifiable {
    let id: UUID
    /// Initials only: Siri and Shortcuts show and speak this.
    let label: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Patient")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(label)")
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
        guard !SystemSurfaceAccess.isLocked else { return [] }
        guard let store = SessionQueries.currentStore() else { return [] }
        let patients = (try? store.listPatients()) ?? []
        return patients.map { PatientEntity(id: $0.id, label: PatientLabel($0).text) }
    }
}
#endif
