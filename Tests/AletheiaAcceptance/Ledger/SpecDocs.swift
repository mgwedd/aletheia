import Foundation

/// Reads the two spec docs. Pure functions over text, so the rules can be
/// unit-tested with small inline docs.
enum SpecDocs {
    struct CheckLine: Equatable {
        let id: String
        /// The journey prefix from the heading the line sits under.
        let heading: String?
        let sentence: String
    }

    struct Criteria {
        var checks: [CheckLine] = []
        var problems: [String] = []
        var ids: Set<String> { Set(checks.map(\.id)) }
        /// Journey prefix to its check IDs, in document order.
        var journeys: [(prefix: String, ids: [String])] {
            var order: [String] = []
            var byPrefix: [String: [String]] = [:]
            for check in checks {
                let prefix = String(check.id.prefix { $0 != "-" })
                if byPrefix[prefix] == nil { order.append(prefix) }
                byPrefix[prefix, default: []].append(check.id)
            }
            return order.map { ($0, byPrefix[$0] ?? []) }
        }
    }

    struct Reference {
        var itemIDs: [String] = []
        /// Checks that at least one item rolls up to.
        var rolledUp: Set<String> = []
        var problems: [String] = []
    }

    // MARK: Criteria

    /// `## 2. Add a patient (PATIENT)`
    private static let headingPattern = #"^## \d+\. .*\(([A-Z]+)\)\s*$"#
    /// `- **PATIENT-03** Type ... → her page opens ...`
    private static let checkPattern = #"^- \*\*([A-Z]+-\d{2})\*\* (.*)$"#

    static func parseCriteria(_ text: String) -> Criteria {
        var result = Criteria()
        var heading: String?
        var seen: Set<String> = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let groups = line.captures(headingPattern) {
                heading = groups[0]
                continue
            }
            guard line.hasPrefix("- **") else { continue }
            guard let groups = line.captures(checkPattern) else {
                result.problems.append("malformed check line (want '- **ID-NN** do → see'): \(line.prefix(60))")
                continue
            }
            let id = groups[0], body = groups[1]
            let prefix = String(id.prefix { $0 != "-" })
            if prefix != heading {
                result.problems.append("\(id): sits under the (\(heading ?? "no")) heading")
            }
            if body.filter({ $0 == "→" }).count != 1 {
                result.problems.append("\(id): needs exactly one →")
            }
            if !seen.insert(id).inserted {
                result.problems.append("\(id): duplicate check ID")
            }
            result.checks.append(CheckLine(id: id, heading: heading, sentence: body))
        }
        return result
    }

    // MARK: Reference

    /// `- **EXP-029** Export refuses while locked.` then a tag line with `qa: EXPORT-07`.
    static func parseReference(_ text: String, knownChecks: Set<String>) -> Reference {
        var result = Reference()
        var seen: Set<String> = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() {
            guard let item = line.captures(#"^- \*\*([A-Z]+-\d{3})\*\* "#) else { continue }
            let id = item[0]
            if !seen.insert(id).inserted { result.problems.append("\(id): duplicate reference ID") }
            result.itemIDs.append(id)
            let tags = index + 1 < lines.count ? lines[index + 1] : ""
            guard let qa = tags.captures(#"`qa: ([A-Z]+-\d{2})`"#) else {
                result.problems.append("\(id): no qa: tag")
                continue
            }
            if knownChecks.contains(qa[0]) {
                result.rolledUp.insert(qa[0])
            } else {
                result.problems.append("\(id): qa: \(qa[0]) is not a check in the walkthrough")
            }
        }
        return result
    }

    // MARK: Cross-checks

    /// `tests` maps a check ID to how many test methods carry it.
    static func coverageProblems(criteria: Criteria, reference: Reference, tests: [String: Int]) -> [String] {
        var problems = criteria.problems + reference.problems
        let known = criteria.ids
        for check in criteria.checks where !reference.rolledUp.contains(check.id) {
            problems.append("\(check.id): no reference item rolls up to it")
        }
        for check in criteria.checks where tests[check.id] == nil {
            problems.append("\(check.id): no test_\(check.id.replacingOccurrences(of: "-", with: "_"))")
        }
        for (id, count) in tests.sorted(by: { $0.key < $1.key }) {
            let name = "test_" + id.replacingOccurrences(of: "-", with: "_")
            if !known.contains(id) { problems.append("\(name) has no check in the walkthrough") }
            if count > 1 { problems.append("\(name): defined \(count) times") }
        }
        return problems
    }

    /// Copy entries (`static let name = ...` in `*Copy.swift`) that no other file
    /// refers to as `Copy.name`. `files` maps a file name to its text.
    static func unusedCopyEntries(files: [String: String]) -> [String] {
        var unused: [String] = []
        let rest = files.filter { !$0.key.hasSuffix("Copy.swift") }.values.joined(separator: "\n")
        for (_, text) in files.sorted(by: { $0.key < $1.key }).filter({ $0.key.hasSuffix("Copy.swift") }) {
            for entry in text.allCaptures(#"static (?:let|var|func) (\w+)"#) {
                let used = rest.range(of: #"\bCopy\.\#(entry)\b"#, options: .regularExpression) != nil
                if !used { unused.append("Copy.\(entry) is used by no test") }
            }
        }
        return unused
    }

    static func expectFailureProblems(files: [String: String]) -> [String] {
        files.sorted(by: { $0.key < $1.key })
            .filter { $0.value.contains("XCTExpectFailure") }
            .map { "\($0.key): XCTExpectFailure; let a known defect fail" }
    }

    /// Fixed delays in the DSL and drivers. `eventually` is the one place that may pause.
    static func fixedDelayProblems(files: [String: String]) -> [String] {
        files.sorted(by: { $0.key < $1.key })
            .filter { ($0.key.hasPrefix("DSL/") || $0.key.hasPrefix("Drivers/")) && $0.key != "DSL/Eventually.swift" }
            .filter { $0.value.range(of: #"Task\.sleep|Thread\.sleep|\bsleep\(|\busleep\("#, options: .regularExpression) != nil }
            .map { "\($0.key): fixed delay; wait with eventually(...) instead" }
    }

    // MARK: Locating the docs and the suite

    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static func loadCriteria() -> Criteria {
        parseCriteria(read("docs/spec/ACCEPTANCE-CRITERIA.md"))
    }

    static func loadReference(knownChecks: Set<String>) -> Reference {
        parseReference(read("docs/spec/BEHAVIOR-REFERENCE.md"), knownChecks: knownChecks)
    }

    /// Sources of the acceptance suite by file name, excluding this folder (which
    /// mentions the things it scans for).
    static func suiteSources() -> [String: String] {
        let suite = repoRoot.appendingPathComponent("Tests/AletheiaAcceptance")
        let ledger = suite.appendingPathComponent("Ledger").path
        var found: [String: String] = [:]
        let walker = FileManager.default.enumerator(at: suite, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift", !url.path.hasPrefix(ledger) else { continue }
            found[String(url.path.dropFirst(suite.path.count + 1))] = try? String(contentsOf: url, encoding: .utf8)
        }
        return found.compactMapValues { $0 }
    }

    private static func read(_ relativePath: String) -> String {
        (try? String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)) ?? ""
    }
}

extension String {
    /// Capture groups of the first match, or nil.
    func captures(_ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: self).map { String(self[$0]) } ?? ""
        }
    }

    /// First capture group of every match.
    func allCaptures(_ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: self, range: NSRange(startIndex..., in: self)).compactMap { match in
            Range(match.range(at: 1), in: self).map { String(self[$0]) }
        }
    }
}
