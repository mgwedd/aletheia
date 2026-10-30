@testable import Aletheia
import AppKit
import Foundation

/// How long the note is.
enum NoteLength {
    case concise, natural, detailed

    var setting: SummaryVerbosity {
        switch self {
        case .concise: .concise
        case .natural: .natural
        case .detailed: .detailed
        }
    }
}

/// The AI effort choice.
enum Effort {
    case fast, normal, focus

    var setting: AnswerEffort {
        switch self {
        case .fast: .fast
        case .normal: .normal
        case .focus: .focus
        }
    }
}

/// The note formats a test names.
enum NoteFormat {
    case summary, soap, dap, birp, girp

    var progress: ProgressNoteFormat {
        switch self {
        case .summary: .narrative
        case .soap: .soap
        case .dap: .dap
        case .birp: .birp
        case .girp: .girp
        }
    }
}

extension Then where Subject == LengthMenu {
    func offersTheLengths() {
        expect(Copy.lengthChoices.allSatisfy(subject.lengths.contains),
               "expected the menu to offer \(Copy.lengthChoices), found \(subject.lengths)")
    }
    func offersAnAIEffortChoice() {
        expect(Copy.effortChoices.allSatisfy(subject.efforts.contains),
               "expected the menu to offer the AI effort levels \(Copy.effortChoices), found \(subject.efforts)")
    }
}

extension Then where Subject == NotePane {
    func endsWithACoverageLine() {
        guard let coverage = subject.coverage else { return fail("the note has no coverage line") }
        expect(coverage.hasPrefix(Copy.coverageLead) && coverage.contains(Copy.coverageCaveat),
               "expected a coverage line saying what was read, found \"\(coverage)\"")
    }

    func countsFollowUpLookups() {
        guard let coverage = subject.coverage else { return fail("the note has no coverage line") }
        expect(coverage.contains(Copy.wholeSessionSummary), "the coverage line leaves out the summary: \"\(coverage)\"")
        expect(coverage.contains(Copy.followUpLookup), "the coverage line counts no follow-up lookups: \"\(coverage)\"")
    }

    func countsNoFollowUpLookups() {
        guard let coverage = subject.coverage else { return fail("the note has no coverage line") }
        expect(coverage.contains(Copy.wholeSessionSummary), "the coverage line leaves out the summary: \"\(coverage)\"")
        expect(!coverage.contains(Copy.followUpLookup), "the coverage line counts follow-up lookups: \"\(coverage)\"")
    }
}

@MainActor extension Then where Subject == NotesTab {
    func offersTheFormatsAndMyNotes() {
        let choices = subject.pickerChoices
        expect(Copy.formatNames.allSatisfy(choices.contains) && choices.contains(Copy.myNotes),
               "expected the picker to offer \(Copy.formatNames) and \(Copy.myNotes), found \(choices)")
    }

    func usesOwnInstructions(for format: NoteFormat, _ text: String) {
        expect(subject.hasOwnInstructions(for: format), "no instructions of its own were kept")
        expectEqual(subject.instructionsInEffect(for: format), text, "the instructions in effect")
    }

    func usesTheDefaultInstructions(for format: NoteFormat) {
        expect(!subject.hasOwnInstructions(for: format), "the customized instructions were not cleared")
        expectEqual(subject.instructionsInEffect(for: format), Prompts.defaultInstructions(for: format.progress),
                    "the instructions in effect")
    }

    func keepsMyNotesAs(_ text: String) {
        expectEqual(subject.myNotesOnDisk, text, "My Notes on disk")
    }
}

extension Then where Subject == NotePane {
    func showsTheEmptyState(for format: NoteFormat) {
        expectEqual(subject.emptyTitle, NoteWords.emptyTitle(format: format.progress), "the empty title")
        expectEqual(subject.generateButton, NoteWords.generateButton(format: format.progress), "the generate button")
    }

    func isWritingWithStop() {
        expect(subject.isWriting && subject.offersStop, "the note is not being written with a Stop button")
        expect(subject.statusLine?.range(of: #"\d+:\d{2}$"#, options: .regularExpression) != nil,
               "the status line has no elapsed time: \(String(describing: subject.statusLine))")
    }

    func keepsTheTextWrittenSoFar(_ text: String) {
        expect(!subject.isWriting, "the note is still being written")
        expect(subject.shown.contains(text), "the note lost the text written so far; it shows \"\(subject.shown)\"")
    }

    func hasTheSoapSections(speakersAre name: String) {
        var position = subject.text.startIndex
        for section in Copy.soapSections {
            guard let found = subject.text.range(of: section, range: position..<subject.text.endIndex) else {
                return fail("the note has no \(section) section after the one before it: \"\(subject.text)\"")
            }
            position = found.upperBound
        }
        expect(subject.text.contains("You") && subject.text.contains(name),
               "speakers should read as You and \(name): \"\(subject.text)\"")
        expect(!subject.text.contains("Y:") && !subject.text.contains("C:"),
               "speaker codes were left in the note: \"\(subject.text)\"")
    }

    func isWaiting(for status: String) {
        expect(subject.isWaiting && subject.waitingStatus == status,
               "expected waiting with \"\(status)\", found \(String(describing: subject.waitingStatus)), waiting: \(subject.isWaiting)")
        expect(subject.offersCancel, "the waiting note has no Cancel button")
    }

    func asksBeforeReplacing(editedText: String) {
        expect(subject.asksBeforeReplacing, "Regenerate replaced the edited note without asking")
        expectEqual(subject.text, editedText, "the edited note")
    }

    func showsOutdatedMessage() {
        expectEqual(subject.outdatedMessage, NoteWords.outdatedMessage, "the outdated message")
    }

    func showsNoOutdatedMessage() {
        expectEqual(subject.outdatedMessage, nil, "the outdated message")
    }

    func showsText(_ text: String) {
        expectEqual(subject.shown, text, "the note")
    }

    func keepsTheMarkdown(_ markdown: String) {
        expect(subject.text.contains(markdown), "the saved note lost \"\(markdown)\": it reads \"\(subject.text)\"")
    }
}

extension Then where Subject == ShownAlert {
    func isTheModelNotDownloadedAlert() {
        expectEqual(subject.title, Copy.notDownloadedTitle, "the alert title")
        expect(subject.offers.contains(Copy.downloadModel), "the alert offers \(subject.offers), not \(Copy.downloadModel)")
    }
}

extension Then where Subject == CopiedNote {
    func isFormattedForAPasteWithAFormattedHeading(_ heading: String, bullet item: String) {
        expectEqual(subject.buttonTitle, Copy.copied, "the button title")
        guard let rich = subject.rich else { return fail("nothing rich went on the pasteboard") }
        let text = rich.string as NSString
        let headingRange = text.range(of: heading)
        guard headingRange.location != NSNotFound else { return fail("the heading \(heading) is missing: \(rich.string)") }
        let font = rich.attribute(.font, at: headingRange.location, effectiveRange: nil) as? NSFont
        expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true, "the heading \(heading) is not bold")
        expect(rich.string.contains("\(Copy.bullet)\t\(item)") || rich.string.contains("\(Copy.bullet) \(item)"),
               "the list item \(item) has no bullet: \(rich.string)")
        expect(!subject.plain.contains("##") && !subject.plain.contains("**"),
               "raw Markdown symbols reached the clipboard: \(subject.plain)")
    }
}

extension Then where Subject == SteeredModel {
    func askedWith(_ text: String) {
        expect(subject.requestTexts.last?.contains(text) == true, "the last request does not contain \"\(text)\"")
    }

    func sentTheTranscriptAsMaterial(containing line: String) {
        guard let last = subject.requestTexts.last,
              let open = last.range(of: "<transcript>"),
              let close = last.range(of: "</transcript>", range: open.upperBound..<last.endIndex) else {
            return fail("the transcript was not sent inside its tags")
        }
        expect(last[open.upperBound..<close.lowerBound].contains(line),
               "the line \"\(line)\" is not inside the transcript tags")
    }
}
