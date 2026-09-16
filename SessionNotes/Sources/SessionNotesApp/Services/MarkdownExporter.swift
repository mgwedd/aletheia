import Foundation

struct SessionExport {
    let date: Date
    let transcript: String
    let summary: String
}

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
            "# Session Notes — \(patientName)",
            "",
            "**Date:** \(dateFormatter.string(from: date))",
            "",
        ]

        let summaryText = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let transcriptText = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !summaryText.isEmpty {
            lines += ["## Summary", "", "_AI-generated. Read alongside the transcript._", "", summaryText, ""]
        }
        if !transcriptText.isEmpty {
            lines += ["## Transcript", "", transcriptText, ""]
        }
        if summaryText.isEmpty && transcriptText.isEmpty {
            lines += ["_No transcript or summary recorded for this session yet._", ""]
        }
        return lines.joined(separator: "\n")
    }

    /// Sessions are expected newest-first (as `Store.listSessions` returns).
    static func patientHistory(patientName: String, notes: String, sessions: [SessionExport]) -> String {
        var lines: [String] = ["# \(patientName) — Session History", ""]

        let notesText = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notesText.isEmpty {
            lines += ["## Patient Notes", "", notesText, ""]
        }

        if sessions.isEmpty {
            lines += ["_No sessions recorded yet._"]
            return lines.joined(separator: "\n")
        }

        for session in sessions {
            let summaryText = session.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let transcriptText = session.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            lines += ["---", "", "## \(dateFormatter.string(from: session.date))", ""]
            if !summaryText.isEmpty {
                lines += ["### Summary", "", summaryText, ""]
            }
            if !transcriptText.isEmpty {
                lines += ["### Transcript", "", transcriptText, ""]
            }
            if summaryText.isEmpty && transcriptText.isEmpty {
                lines += ["_No transcript or summary for this session._", ""]
            }
        }
        return lines.joined(separator: "\n")
    }
}
