@testable import Aletheia
import Foundation

extension Then where Subject == AskPane {
    func answeredAtOnce(quoting line: String) {
        guard let answer = subject.answers.last else { return fail("nothing answered yet") }
        expect(answer.contains("> \(line)"), "expected the answer to quote \"\(line)\", found \"\(answer)\"")
    }

    func saysTheAINeverReadsMyNotes() {
        guard let answer = subject.answers.last else { return fail("nothing answered yet") }
        expect(answer.contains(Copy.aiNeverReadsMyNotes), "expected the answer to say the AI never reads My Notes, found \"\(answer)\"")
    }

    func hasNoAnswerYet() { expect(subject.answers.isEmpty, "an answer is already showing: \(subject.answers)") }

    func showsAnswer(_ text: String) {
        expect(subject.answers.last == text, "expected the answer \"\(text)\", found \(subject.answers)")
    }

    func offersCompact() { expect(subject.offersCompact, "Compact is not offered") }

    func showsTheAccuracyNotice() {
        expectEqual(subject.accuracyNotice, Copy.accuracyNotice, "the notice under the conversation")
    }

    func hasNotCompacted() {
        expect(!subject.bubbles.contains { $0.who == .summary }, "the conversation was already compacted")
    }

    /// The earlier messages were replaced by a summary that stands before `question` and its answer.
    func compactedBefore(answering question: String) {
        let kinds = subject.bubbles
        guard let summary = kinds.firstIndex(where: { $0.who == .summary }) else {
            return fail("the conversation was not compacted; it reads \(kinds.map(\.who))")
        }
        guard let asked = kinds.lastIndex(where: { $0.who == .you && $0.text == question }) else {
            return fail("\"\(question)\" is not in the conversation")
        }
        expect(summary < asked, "the summary comes after the question it should come before")
        expect(kinds.last?.who == .assistant && asked < kinds.count - 1, "the question has no answer after it")
    }

    func hasInTheBox(_ question: String) {
        expectEqual(subject.questionInBox, question, "the question back in the box")
    }

    func neverAsked(_ question: String) {
        expect(!subject.questions.contains(question), "\"\(question)\" was sent anyway")
    }
}

extension Then where Subject == SteeredModel {
    func wasNeverAsked() { expect(subject.requests.isEmpty, "the AI model was asked \(subject.requests.count) time(s)") }
}

extension SteeredModel {
    /// Asked to summarize a conversation so far, it fails.
    func failsToSummarize() {
        answer("Write a summary that will replace it", with: .fails(SummaryFailed()))
    }

    /// Answers every question with text just past a quarter of the window of
    /// the model this Mac runs, so the next question compacts first. The
    /// window follows the Mac's memory, so a fixed length would be too short
    /// on one Mac and longer than the whole window on another.
    func answersPastAQuarterOfTheWindow() {
        let sentence = "She described her week in some detail. "
        let count = ChatMemory.budget() / sentence.count + 20
        fallback(String(repeating: sentence, count: count))
    }
}

struct SummaryFailed: LocalizedError {
    var errorDescription: String? { "The summary could not be written." }
}
