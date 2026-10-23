import SwiftUI
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

/// Handles a tap on one of our Spotlight results: reads the item's identifier,
/// resolves it to a `SpotlightRoute` (nothing while the app is locked), and asks `AppNavigator` to open it.
/// Compiles to a plain passthrough where CoreSpotlight isn't available.
struct SpotlightContinuationModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if canImport(CoreSpotlight)
        content.onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard
                let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                let route = SystemSurfaceAccess.route(
                    forIdentifier: identifier, isLocked: SystemSurfaceAccess.isLocked)
            else { return }
            AppNavigator.shared.open(route)
        }
        #else
        content
        #endif
    }
}
