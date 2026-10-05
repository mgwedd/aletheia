import SwiftUI
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

/// Handles a tap on one of our Spotlight results: reads the item's identifier,
/// resolves it to a `SpotlightRoute`, and asks `AppNavigator` to open it.
/// Compiles to a plain passthrough where CoreSpotlight isn't available.
struct SpotlightContinuationModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if canImport(CoreSpotlight)
        content.onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard
                let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                let route = SpotlightItemBuilder.route(forIdentifier: identifier)
            else { return }
            AppNavigator.shared.open(route)
        }
        #else
        content
        #endif
    }
}
