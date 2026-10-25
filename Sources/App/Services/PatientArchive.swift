import Foundation

/// What one session contributes to a patient's records archive, as plain values
/// so the layout below is a pure function (and safe to build off the main thread).
struct ArchiveSession: Equatable, Sendable {
    var date: Date
    var transcript: String
    /// Saved notes, one per format that has one, already as plain text.
    var notes: [ArchiveNote]
    /// The latest-note file, used only when no per-format note exists (older sessions).
    var summary: String
}

struct ArchiveNote: Equatable, Sendable {
    /// "SOAP", "Summary", ...
    var formatName: String
    var text: String
}

struct ArchiveComment: Equatable, Sendable {
    var anchorSeconds: Double?
    var quotedText: String
    var body: String
    var resolved: Bool
    /// The drafted note this comment is on (e.g. "SOAP"), nil for the transcript.
    var noteLabel: String? = nil
}

struct ArchiveFile: Equatable {
    let path: String
    let text: String
    let modified: Date
}

/// The layout of a patient's records archive: a folder of plain text files, one
/// folder per session, oldest first. Therapists keep this for their own records;
/// PDF, Word and Markdown stay available one session or note at a time.
///
///     <Patient> records/
///       Read me.txt
///       Patient notes.txt
///       Sessions/
///         2026-09-16 14.30/
///           Transcript.txt
///           Note - SOAP.txt
///
/// The therapist's psychotherapy notes and private margin comments are not part
/// of this archive; `PsychotherapyExport` writes them separately.
enum PatientArchive {
    static func files(
        patientName: String, background: String, sessions: [ArchiveSession], exportedOn: Date,
        rootName: String? = nil, hasRecording: (Int) -> Bool = { _ in false }
    ) -> [ArchiveFile] {
        let root = rootName ?? defaultRootName(patientName: patientName)
        var files: [ArchiveFile] = []
        var empty = 0

        let backgroundText = background.trimmingCharacters(in: .whitespacesAndNewlines)
        if !backgroundText.isEmpty {
            files.append(ArchiveFile(path: "\(root)/Patient notes.txt", text: backgroundText + "\n", modified: exportedOn))
        }

        let folders = sessionFolders(for: sessions.map(\.date))
        for index in chronologicalOrder(sessions.map(\.date)) {
            let session = sessions[index]
            let folder = "\(root)/Sessions/\(folders[index])"
            let before = files.count

            let transcript = TranscriptStyler.forReader(session.transcript, callAudioName: Prompts.clientFirstName(patientName)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty {
                files.append(ArchiveFile(path: "\(folder)/Transcript.txt", text: transcript + "\n", modified: session.date))
            }
            var usedNames = Set<String>()
            for note in session.notes {
                let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let name = uniqueName("Note - \(fileSafe(note.formatName))", taken: &usedNames)
                files.append(ArchiveFile(path: "\(folder)/\(name).txt", text: text + "\n", modified: session.date))
            }
            let summary = session.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if session.notes.isEmpty, !summary.isEmpty {
                files.append(ArchiveFile(path: "\(folder)/Summary.txt", text: summary + "\n", modified: session.date))
            }
            if files.count == before, !hasRecording(index) { empty += 1 }
        }

        let readMe = readMeText(
            patientName: patientName, exportedOn: exportedOn, sessionCount: sessions.count - empty, emptyCount: empty
        )
        files.insert(ArchiveFile(path: "\(root)/Read me.txt", text: readMe, modified: exportedOn), at: 0)
        return files
    }

    /// "<Name> records", the archive's top folder.
    static func defaultRootName(patientName: String) -> String {
        fileSafe(patientName.isEmpty ? "Patient" : patientName) + " records"
    }

    /// Each session's folder name under Sessions/, in the order the dates are
    /// given. Folders are assigned oldest first, so same-minute sessions get
    /// " (2)", " (3)" in date order, with the given order breaking ties.
    static func sessionFolders(for dates: [Date]) -> [String] {
        var taken = Set<String>()
        var folders = Array(repeating: "", count: dates.count)
        for index in chronologicalOrder(dates) {
            folders[index] = uniqueFolder(for: dates[index], taken: &taken)
        }
        return folders
    }

    /// Indices of `dates`, oldest first; stable for equal dates.
    static func chronologicalOrder(_ dates: [Date]) -> [Int] {
        dates.indices.sorted { (dates[$0], $0) < (dates[$1], $1) }
    }

    /// `2026-09-16 14.30`, in the Mac's time zone (the one the session list shows), so Finder sorts
    /// the folders in session order. Two sessions in the same minute get " (2)", " (3)".
    static func uniqueFolder(for date: Date, taken: inout Set<String>) -> String {
        uniqueName(stampFormatter.string(from: date), taken: &taken)
    }

    /// Comments as plain text, or nil when there are none.
    static func commentsText(_ comments: [ArchiveComment]) -> String? {
        guard !comments.isEmpty else { return nil }
        let blocks = comments.map { comment -> String in
            var lines: [String] = []
            var head = ""
            if let seconds = comment.anchorSeconds { head = "[\(TranscriptTimeline.format(Int(seconds)))] " }
            if let label = comment.noteLabel { head = "[\(label) note] " }
            let quote = comment.quotedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !quote.isEmpty { head += "\u{201C}\(quote)\u{201D}" }
            if !head.isEmpty { lines.append(head) }
            lines.append(comment.body.trimmingCharacters(in: .whitespacesAndNewlines))
            if comment.resolved { lines.append("(Resolved)") }
            return lines.joined(separator: "\n")
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// A name that is safe as a single path component: no separators or control
    /// characters, no leading dot, trimmed, never empty.
    static func fileSafe(_ name: String) -> String {
        let cleaned = String(name.unicodeScalars.map { scalar -> Character in
            "/\\:*?\"<>|".unicodeScalars.contains(scalar) || scalar.value < 32 ? "-" : Character(scalar)
        })
        var trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix(".") { trimmed.removeFirst() }
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(80))
    }

    // MARK: - Pieces

    static func uniqueName(_ base: String, taken: inout Set<String>) -> String {
        var candidate = base
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) (\(number))"
            number += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    private static func readMeText(patientName: String, exportedOn: Date, sessionCount: Int, emptyCount: Int) -> String {
        var lines = [
            "\(patientName.isEmpty ? "Patient" : patientName): records",
            "Exported on \(longFormatter.string(from: exportedOn)).",
            "",
            "The Sessions folder has one folder per session, oldest first. Each holds that session's transcript and notes as plain text files that open in any text editor.",
            "",
            "Sessions in this export: \(sessionCount)",
        ]
        if emptyCount > 0 {
            lines.append("Sessions with no transcript or note (left out): \(emptyCount)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()

    private static let longFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        return f
    }()
}

/// Plain text for an archive note: the headings and lists without Markdown symbols.
extension PatientArchive {
    static func plainText(fromMarkdown markdown: String) -> String {
        NotePDF.attributedText(markdown: NoteMarkdown.tidy(markdown), title: "", subtitle: "")
            .string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Reads a patient's sessions out of a `Store` into archive values. Runs wherever
/// it is called, so the export calls it off the main actor. A transcript that is
/// present but can't be read throws, so the export fails instead of leaving it
/// out without saying.
enum ArchiveLoader {
    static func load(store: Store, patient: Patient, session: SessionRecord) throws -> ArchiveSession {
        let notes: [ArchiveNote] = ProgressNoteFormat.allCases.compactMap { format in
            guard let text = store.note(for: patient, session: session, format: format),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ArchiveNote(formatName: format.shortName, text: PatientArchive.plainText(fromMarkdown: text))
        }
        return ArchiveSession(
            date: session.date,
            transcript: try store.readTranscript(for: patient, session: session) ?? "",
            notes: notes,
            summary: store.summary(for: patient, session: session).map(PatientArchive.plainText(fromMarkdown:)) ?? ""
        )
    }
}

/// Builds the archive and writes it to `destination`. Synchronous and free of
/// the main actor: the caller runs it on a background task and passes closures
/// for progress and cancellation.
enum PatientArchiveWriter {
    struct Outcome: Equatable {
        let sessionCount: Int
        let fileCount: Int
        let byteCount: Int
        /// Set for an all-records folder export; nil for one patient's zip.
        var patientCount: Int? = nil
    }

    static func write(
        patientName: String,
        background: String,
        sessionCount: Int,
        loadSession: (Int) throws -> ArchiveSession,
        to destination: URL,
        exportedOn: Date = Date(),
        progress: (Double, String) -> Void,
        isCancelled: () -> Bool
    ) throws -> Outcome {
        var sessions: [ArchiveSession] = []
        for index in 0..<sessionCount {
            if isCancelled() { throw CancellationError() }
            progress(0.9 * Double(index) / Double(max(sessionCount, 1)), "Reading session \(index + 1) of \(sessionCount)")
            sessions.append(try loadSession(index))
        }
        if isCancelled() { throw CancellationError() }
        progress(0.92, "Putting the files together")
        let files = PatientArchive.files(
            patientName: patientName, background: background, sessions: sessions, exportedOn: exportedOn
        )
        let zip = try ZipArchive.data(for: files.map {
            ZipArchive.Entry(path: $0.path, data: Data($0.text.utf8), modified: $0.modified)
        })
        if isCancelled() { throw CancellationError() }
        progress(0.97, "Saving")
        try zip.write(to: destination, options: .atomic)
        progress(1, "Done")
        return Outcome(sessionCount: sessions.count, fileCount: files.count, byteCount: zip.count)
    }
}
