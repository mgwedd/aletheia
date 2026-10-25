import Foundation

/// How a Doctor check came out. Ordered by severity so a report's overall
/// status is simply the worst of its checks.
enum DoctorStatus: Int, Comparable, Equatable {
    case ok = 0
    case warning = 1
    case failed = 2

    static func < (lhs: DoctorStatus, rhs: DoctorStatus) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Short label used in the on-screen list and the copied report.
    var label: String {
        switch self {
        case .ok: return "OK"
        case .warning: return "Warning"
        case .failed: return "Problem"
        }
    }
}

/// Where a check sits in the Doctor list.
enum DoctorCategory: Int, CaseIterable, Comparable {
    case dataFolder
    case database
    case encryption
    case backups
    case records
    case tools

    static func < (lhs: DoctorCategory, rhs: DoctorCategory) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .dataFolder: return "Data folder"
        case .database: return "Database"
        case .encryption: return "Encryption"
        case .backups: return "Snapshots & backups"
        case .records: return "Records"
        case .tools: return "Tools & permissions"
        }
    }
}

/// An optional fix action offered on a Doctor row so the therapist has a
/// one-click path to resolve the issue.
enum DoctorAction: String, Equatable {
    case openSettings
    case openSystemSettings
    case reviewRecords
    case setupAssistant
    case checkForUpdates

    var label: String {
        switch self {
        case .openSettings: return "Open Settings"
        case .openSystemSettings: return "Open System Settings"
        case .reviewRecords: return "Review records"
        case .setupAssistant: return "Set up…"
        case .checkForUpdates: return "Check for Updates…"
        }
    }

    /// What the Doctor window does for this action. Kept apart from the view so
    /// it can be tested: a button that only sends an AppKit selector nothing
    /// handles does nothing, and the user sees nothing happen.
    var route: DoctorActionRoute {
        switch self {
        case .openSettings: return .settings(nil)
        case .setupAssistant: return .settings(.setupAssistant)
        case .openSystemSettings: return .systemSettings
        case .reviewRecords: return .reviewRecords
        case .checkForUpdates: return .updateCheck
        }
    }
}

enum DoctorActionRoute: Equatable {
    /// Open the Settings window, showing `request` when there is one.
    case settings(SettingsRequest?)
    case systemSettings
    case reviewRecords
    /// Run an update check and bring the main window forward to show it.
    case updateCheck
}

/// One line of the Doctor report: what was checked, how it came out, in plain
/// language, and what to do next. **Every string here must be PHI-free** — check
/// names, statuses, counts, versions and error kinds only; never a patient or
/// session name, note text, or a file name below the data folder root. The
/// runner is written to that rule, and `DoctorReport.plainText` runs the whole
/// report through `DoctorRedactor` as a second line of defence.
struct DoctorCheck: Identifiable, Equatable {
    /// Stable identifier ("dataFolder.space"), so tests and the UI can refer to a
    /// check without matching on display strings.
    let id: String
    let category: DoctorCategory
    let title: String
    let status: DoctorStatus
    /// What was found, in plain language.
    let detail: String
    /// What to do about it — nil when the check passed and there's nothing to do.
    let nextStep: String?
    /// An optional one-click fix action for the check.
    let action: DoctorAction?

    init(
        id: String,
        category: DoctorCategory,
        title: String,
        status: DoctorStatus,
        detail: String,
        nextStep: String? = nil,
        action: DoctorAction? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.status = status
        self.detail = detail
        self.nextStep = nextStep
        self.action = action
    }
}

/// Facts about the running app and Mac that go at the top of a report. All
/// PHI-free by construction.
struct DoctorEnvironment: Equatable {
    var appVersion: String
    var buildTier: String
    var macOSVersion: String
    /// The newest database schema version this build understands.
    var supportedSchemaVersion: Int
    /// This user's home directory, so the report can redact it to `~`.
    var homeDirectory: String
    /// The chosen data folder, so the report can redact anything below it.
    var dataRoot: String?
    /// Values that must never appear in the report wherever they turn up: the
    /// account name, and any patient names or folder slugs the caller knows.
    var knownTerms: [String] = []

    static func current(dataRoot: URL?, knownTerms: [String] = []) -> DoctorEnvironment {
        DoctorEnvironment(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildTier: BuildTier.current.rawValue,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            supportedSchemaVersion: SchemaMigrator.latestVersion,
            homeDirectory: NSHomeDirectory(),
            dataRoot: dataRoot?.path,
            // The account's real home folder name, not NSHomeDirectory(): in the sandbox that is
            // the app container ending in "Data", which would blank out "Data folder" in the report.
            knownTerms: [NSUserName(), DataFolderPolicy.realHome.lastPathComponent] + knownTerms
        )
    }
}

/// The checks in one category, for display.
struct DoctorGroup: Identifiable, Equatable {
    let category: DoctorCategory
    let checks: [DoctorCheck]
    var id: Int { category.rawValue }
}

/// The outcome of one Doctor run.
struct DoctorReport: Equatable {
    let checks: [DoctorCheck]
    let generatedAt: Date
    let environment: DoctorEnvironment

    /// The worst status of any check (`.ok` for an empty report).
    var overall: DoctorStatus { checks.map(\.status).max() ?? .ok }

    func count(_ status: DoctorStatus) -> Int { checks.filter { $0.status == status }.count }

    /// One-line headline for the top of the window.
    var summary: String {
        switch overall {
        case .ok:
            return "Everything checked looks healthy."
        case .warning:
            let n = count(.warning)
            return "\(n) thing\(n == 1 ? "" : "s") worth a look — nothing is broken."
        case .failed:
            let n = count(.failed)
            return "\(n) problem\(n == 1 ? "" : "s") found that could stop notes or chat from saving."
        }
    }

    /// Checks grouped by category, in display order, empty categories dropped.
    var grouped: [DoctorGroup] { grouped(onlyIssues: false) }

    /// As `grouped`, optionally keeping only the checks that aren't `.ok`
    /// (categories left empty by the filter are dropped).
    func grouped(onlyIssues: Bool) -> [DoctorGroup] {
        DoctorCategory.allCases.compactMap { category -> DoctorGroup? in
            let inCategory = checks.filter { $0.category == category && (!onlyIssues || $0.status != .ok) }
            guard !inCategory.isEmpty else { return nil }
            return DoctorGroup(category: category, checks: inCategory)
        }
    }

    /// The window's title: "1 problem, 2 warnings", "3 warnings", or
    /// "All checks passed".
    var headline: String {
        let problems = count(.failed)
        let warnings = count(.warning)
        var parts: [String] = []
        if problems > 0 { parts.append("\(problems) problem\(problems == 1 ? "" : "s")") }
        if warnings > 0 { parts.append("\(warnings) warning\(warnings == 1 ? "" : "s")") }
        return parts.isEmpty ? "All checks passed" : parts.joined(separator: ", ")
    }

    /// One sentence under the headline saying what the result means.
    var explanation: String {
        switch overall {
        case .ok:
            return "Everything checked looks healthy."
        case .warning:
            return "Nothing is broken, but these are worth a look."
        case .failed:
            return "Problems can stop notes, chat or transcription from working. Each one says what to do next."
        }
    }

    /// "13 checks" / "1 check".
    var checkCountDescription: String {
        "\(checks.count) check\(checks.count == 1 ? "" : "s")"
    }

    /// "just now", "2 minutes ago", "yesterday" — relative to `now`.
    func lastRunDescription(now: Date) -> String {
        if now.timeIntervalSince(generatedAt) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: generatedAt, relativeTo: now)
    }

    /// A PHI-safe plain-text report for pasting into an email or support note.
    ///
    /// Contains check names, statuses, counts, versions, the macOS version and
    /// error kinds. Never patient names, session names, note text, or file names
    /// below the data folder root; the home directory is shown as `~`. The whole
    /// text passes through `DoctorRedactor` last, so even a check that slipped a
    /// path into its detail can't leak one.
    func plainText() -> String {
        var lines: [String] = []
        lines.append("Aletheia Doctor report")
        lines.append("Generated: \(Self.timestamp(generatedAt))")
        lines.append("Aletheia \(environment.appVersion) (\(environment.buildTier) build), macOS \(environment.macOSVersion)")
        lines.append("Supported database schema: v\(environment.supportedSchemaVersion)")
        lines.append("Result: \(count(.failed)) problem(s), \(count(.warning)) warning(s), \(count(.ok)) OK")
        for group in grouped {
            lines.append("")
            lines.append(group.category.title.uppercased())
            for check in group.checks {
                lines.append("[\(check.status.label)] \(check.title): \(check.detail)")
                if let next = check.nextStep {
                    lines.append("    Next: \(next)")
                }
            }
        }
        let redactor = DoctorRedactor(
            homeDirectory: environment.homeDirectory, dataRoot: environment.dataRoot, knownTerms: environment.knownTerms)
        return redactor.redact(lines.joined(separator: "\n"))
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

/// Scrubs identifying values out of report text so a copied report is safe to share.
///
/// - Anything at or below `<dataRoot>/` is collapsed to `<data folder>/…` — the
///   rest of that line is dropped, because a path below the root can contain a
///   patient or session name (legacy patient folders may still have names,
///   and session folders include dates of service). A bare data-root path
///   (without a trailing slash) becomes `<data folder>`.
/// - The user's home directory becomes `~`, and so does any other `/Users/<name>`.
/// - UUIDs (patient folder ids) become `<id>`; `Patients/…` and legacy
///   `yyyy-MM-dd_…` session folder names are dropped wherever they appear.
/// - Every `knownTerms` value (account name, patient names, slugs) is replaced
///   by value, case-insensitively.
/// - Any absolute path still left collapses to `<path>`.
struct DoctorRedactor: Equatable {
    var homeDirectory: String
    var dataRoot: String?
    var knownTerms: [String] = []

    /// Terms shorter than this are ignored: they'd match inside ordinary words.
    static let minimumTermLength = 3
    /// Single words taken from a patient's name must be at least this long, so a
    /// short given name ("Al", "Sam") can't blank out everyday words in the report.
    static let minimumNamePartLength = 4

    /// What to redact for a set of patients: each full display name and folder
    /// slug, plus each word of the name that is long enough to be safe on its own.
    /// Initials are never included (too short to match safely).
    static func terms(forPatients patients: [(name: String, slug: String)]) -> [String] {
        var out: [String] = []
        for patient in patients {
            out.append(patient.name)
            out.append(patient.slug)
            let parts = patient.name.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" && $0 != "-" })
            out += parts.map(String.init).filter { $0.count >= minimumNamePartLength }
        }
        return out
    }

    /// Replaces `term` wherever it appears as a whole word, ignoring case and
    /// diacritics ("jose" matches "José"). Matching is literal, so characters
    /// like `.` or `(` in a name are not treated as a pattern. A match flanked by
    /// letters ("Ann" inside "Annual") is left alone.
    private static func replacingWholeWord(_ term: String, in text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        while cursor < text.endIndex, let range = text.range(of: term, options: options, range: cursor..<text.endIndex) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            let flankedByLetter = (before?.isLetter ?? false) || (after?.isLetter ?? false)
            result += text[cursor..<range.lowerBound]
            result += flankedByLetter ? String(text[range]) : "<redacted>"
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    func redact(_ text: String) -> String {
        var out = text

        if let root = dataRoot, !root.isEmpty {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            out = out
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    let line = String(line)
                    guard let range = line.range(of: prefix) else { return line }
                    return String(line[..<range.lowerBound]) + "<data folder>/…"
                }
                .joined(separator: "\n")
            // A root inside the home folder is already shown as `~/…`; one elsewhere
            // (an external drive) would otherwise show its volume name.
            if root.count > 1, !(homeDirectory.count > 1 && root.hasPrefix(homeDirectory)) {
                let bare = root.hasSuffix("/") ? String(root.dropLast()) : root
                out = out.replacingOccurrences(
                    of: NSRegularExpression.escapedPattern(for: bare) + "(?![A-Za-z0-9_-])(?!\\.[A-Za-z0-9])",
                    with: "<data folder>", options: .regularExpression)
            }
        }

        // The exact home directory (may be somewhere other than /Users, e.g.
        // /var/root), matched only at a name boundary so "/Users/mike" doesn't
        // eat the front of "/Users/mike2".
        if homeDirectory.count > 1 {
            let pattern = NSRegularExpression.escapedPattern(for: homeDirectory) + "(?![A-Za-z0-9_.-])"
            out = out.replacingOccurrences(of: pattern, with: "~", options: .regularExpression)
        }
        // Any other local user's home.
        out = out.replacingOccurrences(of: "/Users/[^/\\s]+", with: "~", options: .regularExpression)

        // Patient folder ids, patient and session folder names.
        out = out.replacingOccurrences(
            of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
            with: "<id>", options: .regularExpression)
        out = out.replacingOccurrences(of: "Patients/\\S*", with: "<patient folder>", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\d{4}-\\d{2}-\\d{2}_[^\\s/]+", with: "<session folder>", options: .regularExpression)

        // Known identifying values, longest first so a full name goes before its parts.
        let terms = Set(knownTerms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= Self.minimumTermLength })
        for term in terms.sorted(by: { $0.count > $1.count }) {
            out = Self.replacingWholeWord(term, in: out)
        }

        // Whatever absolute path is left: keep nothing below the filesystem root.
        out = out.replacingOccurrences(
            of: "(?<![\\w~>.<])/(?:[\\w.@+-]+/?)+", with: "<path>", options: .regularExpression)
        return out
    }
}
