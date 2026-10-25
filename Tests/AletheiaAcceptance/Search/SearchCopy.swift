extension Copy {
    /// The groups of results, in the order they are shown.
    static let searchGroups = ["Patients", "Sessions", "Psychotherapy notes", "Progress notes", "Comments", "Transcripts"]

    /// What the results say when nothing matched a finished search.
    static func noResults(for typed: String) -> String { "No results for \u{201C}\(typed)\u{201D}" }

    /// The line above results while one session is still being indexed.
    static let indexingOneSession = "Indexing 1 session; results may be incomplete."

    /// The row under a group that has more to show.
    static func showMore(_ count: Int) -> String { "Show \(count) more" }
}
