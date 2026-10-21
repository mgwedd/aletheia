import Foundation

/// Renders sessions to plain Markdown the therapist can save, print, or drop
/// into another document. Pure string building so it's easy to test and has
/// no dependency on the file layer.
enum MarkdownExporter {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        return f
    }()

    static func session(date: Date, patientName: String, transcript: String?, summary: String?) -> String {
        var lines: [String] = [
            "# \(patientName)",
            "",
            "**Date:** \(dateFormatter.string(from: date))",
            "",
        ]

        let summaryText = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let transcriptText = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !summaryText.isEmpty {
            lines += ["## Summary", "", summaryText, ""]
        }
        if !transcriptText.isEmpty {
            lines += ["## Transcript", "", transcriptText, ""]
        }
        if summaryText.isEmpty && transcriptText.isEmpty {
            lines += ["_No transcript or summary recorded for this session yet._", ""]
        }
        return lines.joined(separator: "\n")
    }
}
