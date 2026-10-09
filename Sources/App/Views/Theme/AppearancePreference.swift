import AppKit

/// The app's Light / Dark / System choice (Settings → Appearance).
///
/// Applied as `NSApplication.appearance`, the AppKit-level override, rather
/// than SwiftUI's `.preferredColorScheme`: the app-wide appearance reaches every
/// window, sheet, menu, the menu bar extra and AppKit views such as the
/// transcript's text view, and setting it back to `nil` returns to following
/// the system immediately. Asset-catalog colors (`Theme`) resolve against it.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let `default`: AppearancePreference = .system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The appearance to force, or `nil` to follow the system.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }

    /// Sets the app-wide appearance. Called from the main thread only: at
    /// launch (`AppDelegate`) and when the setting changes in Settings.
    func apply() {
        let name = appearanceName
        MainActor.assumeIsolated {
            NSApplication.shared.appearance = name.flatMap(NSAppearance.init(named:))
        }
    }
}
