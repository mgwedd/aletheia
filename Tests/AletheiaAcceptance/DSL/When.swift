import Foundation

/// Does what the user does. Core verbs live here; each journey adds its own in
/// `<Journey>/<Journey>DSL.swift` with `extension When { ... }`.
@MainActor
struct When {
    let app: InProcessDriver
}
