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

    init(id: String, category: DoctorCategory, title: String, status: DoctorStatus, detail: String, nextStep: String? = nil) {
        self.id = id
        self.category = category
        self.title = title
        self.status = status
        self.detail = detail
        self.nextStep = nextStep
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

    static func current(dataRoot: URL?) -> DoctorEnvironment {
        DoctorEnvironment(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildTier: BuildTier.current.rawValue,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            supportedSchemaVersion: SchemaMigrator.latestVersion,
            homeDirectory: NSHomeDirectory(),
            dataRoot: dataRoot?.path
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
        let redactor = DoctorRedactor(homeDirectory: environment.homeDirectory, dataRoot: environment.dataRoot)
        return redactor.redact(lines.joined(separator: "\n"))
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

/// Scrubs paths out of report text so a copied report is safe to share.
///
/// - Anything at or below `<dataRoot>/` is collapsed to `<data folder>/…` — the
///   rest of that line is dropped, because a path below the root can contain a
///   patient or session name (folder names are `Patients/<Patient-Slug>/…`).
/// - The user's home directory becomes `~`, and so does any other `/Users/<name>`.
struct DoctorRedactor: Equatable {
    var homeDirectory: String
    var dataRoot: String?

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
        return out
    }
}
