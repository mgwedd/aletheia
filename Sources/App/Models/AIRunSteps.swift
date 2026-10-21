import Foundation

/// Where a multi-call run is overall, for a progress bar: `done` of `total`
/// calls finished. The call in flight counts as half done, so the bar moves as
/// soon as work starts and never reads full before the last call ends.
struct AIRunSteps: Equatable {
    let done: Int
    let total: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max((Double(done) + 0.5) / Double(total), 0), 1)
    }
}
