import Foundation

/// One session's psychotherapy note and the private margin comments on its
/// transcript, as plain values for the separate psychotherapy export.
struct PsychotherapyNoteEntry: Equatable, Sendable {
    var date: Date
    /// The note as the editor stores it (Markdown).
    var note: String
    var comments: [ArchiveComment]

    var isEmpty: Bool {
        note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && comments.isEmpty
    }
}

/// The separate export of psychotherapy notes. They are never mixed into the
/// clinical record's exports (`PatientArchive`, the progress-note export), and
/// every call here refuses unless the therapist has confirmed she has the
/// patient's authorization.
enum PsychotherapyExport {
    enum ExportError: Error, Equatable {
        case notAuthorized
        case nothingToExport
    }

    /// The first line of every file this export writes.
    static let title = "Psychotherapy note: keep separate from the medical record"

    static let confirmationTitle = "Export psychotherapy notes?"
    static let confirmationMessage =
        "Psychotherapy notes are kept separate from the clinical record. Export them only with the patient's written authorization or another basis the law allows, and store the file apart from the medical record."
    static let confirmButton = "I have authorization: Export"

    // MARK: One session

    /// The document for one session's psychotherapy note, titled as above so it
    /// can't be mistaken for a progress note.
    static func sessionDocument(
        patientName: String, date: Date, note: String, authorized: Bool
    ) throws -> ExportDocument {
        guard authorized else { throw ExportError.notAuthorized }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExportError.nothingToExport }
        return ExportDocument(
            title: title,
            subtitle: "\(patientName) · \(longDate.string(from: date))",
            markdown: text
        )
    }

    /// File name (without extension): initials and date, never the full name.
    static func sessionFileBase(patientName: String, date: Date) -> String {
        FileSaver.fileName(PatientLabel(name: patientName).text, dayStamp.string(from: date), "Psychotherapy note")
    }

    // MARK: Whole patient

    /// A patient's psychotherapy notes and private comments as plain text files,
    /// one folder per session that has any, oldest first.
    static func archiveFiles(
        patientName: String, entries: [PsychotherapyNoteEntry], exportedOn: Date, authorized: Bool
    ) throws -> [ArchiveFile] {
        guard authorized else { throw ExportError.notAuthorized }
        let root = PatientArchive.fileSafe(patientName.isEmpty ? "Patient" : patientName) + " psychotherapy notes"
        let present = entries.filter { !$0.isEmpty }
        guard !present.isEmpty else { throw ExportError.nothingToExport }
        let folders = PatientArchive.sessionFolders(for: present.map(\.date))
        var files = [ArchiveFile(
            path: "\(root)/Read me.txt",
            text: [
                title,
                "Exported on \(longDate.string(from: exportedOn)).",
                "",
                "These are the therapist's private notes and margin comments, kept apart from the clinical record. Keep this folder separate from the medical record.",
                "",
                "Sessions in this export: \(present.count)",
            ].joined(separator: "\n") + "\n",
            modified: exportedOn
        )]
        for index in PatientArchive.chronologicalOrder(present.map(\.date)) {
            let entry = present[index]
            let folder = "\(root)/Sessions/\(folders[index])"
            let note = PatientArchive.plainText(fromMarkdown: entry.note)
            if !note.isEmpty {
                files.append(ArchiveFile(
                    path: "\(folder)/Psychotherapy note.txt", text: title + "\n\n" + note + "\n", modified: entry.date))
            }
            if let comments = PatientArchive.commentsText(entry.comments) {
                files.append(ArchiveFile(
                    path: "\(folder)/Private comments.txt", text: title + "\n\n" + comments, modified: entry.date))
            }
        }
        return files
    }

    /// Builds the archive and writes it to `destination` as a zip, like
    /// `PatientArchiveWriter.write`.
    static func write(
        patientName: String,
        sessionCount: Int,
        loadEntry: (Int) throws -> PsychotherapyNoteEntry,
        to destination: URL,
        authorized: Bool,
        exportedOn: Date = Date(),
        progress: (Double, String) -> Void,
        isCancelled: () -> Bool
    ) throws -> PatientArchiveWriter.Outcome {
        guard authorized else { throw ExportError.notAuthorized }
        var entries: [PsychotherapyNoteEntry] = []
        for index in 0..<sessionCount {
            if isCancelled() { throw CancellationError() }
            progress(0.9 * Double(index) / Double(max(sessionCount, 1)), "Reading session \(index + 1) of \(sessionCount)")
            entries.append(try loadEntry(index))
        }
        let files = try archiveFiles(patientName: patientName, entries: entries, exportedOn: exportedOn, authorized: authorized)
        let zip = try ZipArchive.data(for: files.map {
            ZipArchive.Entry(path: $0.path, data: Data($0.text.utf8), modified: $0.modified)
        })
        if isCancelled() { throw CancellationError() }
        progress(0.97, "Saving")
        try zip.write(to: destination, options: .atomic)
        progress(1, "Done")
        return PatientArchiveWriter.Outcome(
            sessionCount: entries.filter { !$0.isEmpty }.count, fileCount: files.count, byteCount: zip.count)
    }

    /// Reads one session's entry out of a `Store`.
    static func load(store: Store, session: SessionRecord) -> PsychotherapyNoteEntry {
        PsychotherapyNoteEntry(
            date: session.date,
            note: store.psychotherapyNote(for: session),
            comments: store.comments(for: session).map {
                ArchiveComment(anchorSeconds: $0.anchorSeconds, quotedText: $0.quotedText, body: $0.body, resolved: $0.resolved,
                    noteLabel: $0.format?.shortName)
            }
        )
    }

    private static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        return f
    }()

    private static let dayStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
