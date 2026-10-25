import Foundation

/// The question asked before patient data is saved outside the data folder: what
/// is leaving, for whom, and that the file is not encrypted. Nothing is written
/// until `resolve(confirmed: true)` runs `proceed`; cancelling runs nothing. Pure,
/// so it's unit-tested.
struct ExportConfirmation: Identifiable {
    /// How much leaves. Only a single note may be exempted from the question.
    enum Scope: Equatable {
        case singleNote
        case session
        case patientWide
        /// Psychotherapy notes on their own: always asks, in the authorization wording.
        case psychotherapy
    }

    let id = UUID()
    /// The patient's initials, never the full name.
    let patientLabel: String
    /// What leaves, e.g. "1 session (note and transcript)" or "3 sessions".
    let contents: String
    /// The kind of file that will be written, e.g. "PDF".
    let fileType: String
    let scope: Scope
    private let proceed: () -> Void

    init(patientName: String, noun: String, count: Int, fileType: String, scope: Scope, proceed: @escaping () -> Void) {
        patientLabel = PatientLabel.text(
            forName: patientName,
            surface: .exportFilename,
            policy: .init(showFullName: false, isLocked: false)
        )
        contents = Self.describe(noun: noun, count: count)
        self.fileType = fileType
        self.scope = scope
        self.proceed = proceed
    }

    var title: String {
        scope == .psychotherapy ? PsychotherapyExport.confirmationTitle : "Save a copy of \(patientLabel)'s records?"
    }

    var message: String {
        if scope == .psychotherapy { return PsychotherapyExport.confirmationMessage }
        return "This saves \(contents) as a \(fileType) file outside Aletheia's data folder. "
            + "The file is not encrypted, and Aletheia can't protect it once it's saved."
    }

    var advice: String {
        if scope == .psychotherapy {
            return "\(patientLabel): \(contents) as a \(fileType) file outside Aletheia's data folder, not encrypted. "
                + "Save it only to a place you control, apart from the medical record."
        }
        return "Save it only to a place you control, such as an encrypted disk, and delete it when you're done."
    }

    static let confirmTitle = "Export"

    /// The confirm button: the authorization wording for psychotherapy notes.
    var confirmButtonTitle: String {
        scope == .psychotherapy ? PsychotherapyExport.confirmButton : Self.confirmTitle
    }
    static let dontAskAgainTitle = "Don't ask again for single-note exports"

    /// Whether the question is shown. A patient-wide, session-with-transcript or
    /// psychotherapy export always asks; a single note skips it only when the therapist opted out.
    func needsAsking(skipSingleNote: Bool) -> Bool {
        !(scope == .singleNote && skipSingleNote)
    }

    /// Whether the sheet offers "don't ask again".
    var offersDontAskAgain: Bool { scope == .singleNote }

    /// Asks through `present`, or runs the export straight away when the
    /// therapist opted out for single notes. The one entry point for any
    /// single-note export action.
    func begin(skipSingleNote: Bool, present: (ExportConfirmation) -> Void) {
        if needsAsking(skipSingleNote: skipSingleNote) {
            present(self)
        } else {
            resolve(confirmed: true)
        }
    }

    /// Runs the export only when the therapist confirmed.
    func resolve(confirmed: Bool) {
        guard confirmed else { return }
        proceed()
    }

    private static func describe(noun: String, count: Int) -> String {
        "\(count) \(count == 1 ? noun : noun + "s")"
    }
}
