import Foundation

/// How a patient is named on surfaces outside the app window (Spotlight, App
/// Intents, and the like). The one place that decides it: callers hand a
/// `PatientLabel` to a builder instead of a raw name, so a full name can't reach
/// a system-wide surface by accident. Pure, so it's unit-tested.
///
/// The label is the patient's dotted initials ("J.D."), never the name.
struct PatientLabel: Equatable {
    /// The text to show, e.g. "J.D." ("?" for a blank name).
    let text: String

    init(_ patient: Patient) {
        self.init(name: patient.name)
    }

    init(name: String) {
        let monogram = PatientInitials.from(name)
        text = monogram == "?" ? monogram : monogram.map { "\($0)." }.joined()
    }
}

/// Whether records may be opened or revealed from outside the app window. They
/// may not while the app or the data folder is locked.
enum SystemSurfaceAccess {
    /// Mirrors the app and data-folder locks (see `SessionSearch.mayOpenIndex`);
    /// readable from any thread, including an App Intent.
    static var isLocked: Bool { !SessionSearch.mayOpenIndex }

    /// The route a Spotlight tap should open: nil while locked, so a stale
    /// result can't navigate to a record behind the lock screen.
    static func route(forIdentifier identifier: String, isLocked: Bool) -> SpotlightRoute? {
        guard !isLocked else { return nil }
        return SpotlightItemBuilder.route(forIdentifier: identifier)
    }
}
