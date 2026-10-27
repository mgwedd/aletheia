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

    /// `consent` is the body of the "Recording consent" section, one fact per
    /// line; nil leaves the section out.
    static func session(date: Date, patientName: String, transcript: String?, summary: String?,
                        consent: [String]? = nil) -> String {
        var lines: [String] = [
            "# \(patientName)",
            "",
            "**Date:** \(dateFormatter.string(from: date))",
            "",
        ]

        let summaryText = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let transcriptText = transcript.map { TranscriptStyler.forReader($0, callAudioName: Prompts.clientFirstName(patientName)) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !summaryText.isEmpty {
            lines += ["## Summary", "", summaryText, ""]
        }
        if !transcriptText.isEmpty {
            lines += ["## Transcript", "", transcriptText, ""]
        }
        if let consent, !consent.isEmpty {
            lines += ["## \(RecordingConsent.exportHeading)", ""] + consent.map { "- \($0)" } + [""]
        }
        if summaryText.isEmpty && transcriptText.isEmpty {
            lines += ["_No transcript or summary recorded for this session yet._", ""]
        }
        return lines.joined(separator: "\n")
    }
}
