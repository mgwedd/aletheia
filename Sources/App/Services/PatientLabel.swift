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

    // MARK: Surface policy

    /// Where a patient is being named.
    enum Surface: CaseIterable {
        case inApp, notification, menuBar, intent, spotlight, calendar, reminder, exportFilename
    }

    /// What the clinician allows, and whether the app is locked right now.
    struct Policy: Equatable {
        /// The opt-in to show full names outside the app's own windows.
        var showFullName: Bool
        var isLocked: Bool

        init(showFullName: Bool, isLocked: Bool) {
            self.showFullName = showFullName
            self.isLocked = isLocked
        }

        /// The policy right now: the opt-in plus the live lock state.
        static func current(showFullName: Bool) -> Policy {
            Policy(showFullName: showFullName, isLocked: SystemSurfaceAccess.isLocked)
        }
    }

    /// Shown when a patient has no name.
    static let blankFallback = "Client"

    /// Whether `surface` shows the full name under `policy`. The app's own
    /// windows always do; every other surface shows initials unless the clinician
    /// opted in, and never while locked.
    static func showsFullName(surface: Surface, policy: Policy) -> Bool {
        if surface == .inApp { return true }
        return policy.showFullName && !policy.isLocked
    }

    static func text(forName name: String, surface: Surface, policy: Policy) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return blankFallback }
        return showsFullName(surface: surface, policy: policy) ? trimmed : PatientLabel(name: trimmed).text
    }

    static func text(for patient: Patient, surface: Surface, policy: Policy) -> String {
        text(forName: patient.name, surface: surface, policy: policy)
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
