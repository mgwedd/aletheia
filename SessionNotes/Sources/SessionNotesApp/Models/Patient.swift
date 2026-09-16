import Foundation

struct Patient: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var notes: String
    let createdAt: Date
    /// Folder name on disk, e.g. "Jane-Doe" or "Jane-Doe-2" if the name collides.
    let slug: String

    init(id: UUID = UUID(), name: String, notes: String = "", createdAt: Date = Date(), slug: String) {
        self.id = id
        self.name = name
        self.notes = notes
        self.createdAt = createdAt
        self.slug = slug
    }
}
