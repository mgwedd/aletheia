@testable import Aletheia
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
