import Foundation

/// When a sheet that was presented before the app locked must go away. The app
/// lock bumps a generation counter each time it engages; a sheet remembers the
/// generation it was shown under and is dismissed once the counter moves on. A
/// dismissed sheet is never presented again by the unlock itself: its owner sets
/// the flag back to false, so the user has to ask for the sheet again.
enum LockSheetPolicy {
    static func shouldDismiss(presentedGeneration: Int, currentGeneration: Int) -> Bool {
        presentedGeneration != currentGeneration
    }
}
