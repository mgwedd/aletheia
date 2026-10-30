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

    func showsTheEmptyPrompt() {
        expectEqual(subject.emptyTitle, Copy.askEmptyTitle, "the prompt over an empty conversation")
    }

    func showsQuestionAsBubble(_ question: String) {
        expect(subject.questions.contains(question), "the question is not in the conversation: \(subject.questions)")
    }

    func streamsWithStop() {
        expect(subject.isAnswering && subject.offersStop,
               "the answer is not streaming with a Stop button (streaming \(subject.isAnswering), Stop \(subject.offersStop))")
    }

    func showsReadLine() {
        expect(subject.notices.contains { $0.hasPrefix(Copy.readLead) }, "no \"Read:\" line under the answer, notices \(subject.notices)")
    }

    func keepsAnswerSoFar(_ text: String) {
        expect(subject.answers.last == text, "the answer written so far was lost: \(subject.answers)")
    }

    func isWaitingWithCancel() {
        expect(subject.isWaiting && subject.offersCancel && subject.waitingStatus != nil,
               "the question is not waiting with a Cancel button (waiting \(subject.isWaiting), Cancel \(subject.offersCancel))")
    }

    func doesNotShowQuestion(_ question: String) {
        expect(!subject.questions.contains(question), "the unanswered question is still in the conversation: \(subject.questions)")
    }

    func showsEarlierExchange(question: String, answer: String) {
        let asked = subject.bubbles.contains { $0.who == .you && $0.text == question }
        let answered = subject.bubbles.contains { $0.who == .assistant && $0.text == answer }
        expect(asked && answered, "the earlier question and answer are not both shown: \(subject.bubbles)")
    }

    func showsQuestionOnlyOnce(_ question: String) {
        expectEqual(subject.questions.filter { $0 == question }.count, 1, "times the question is in the conversation")
    }

    func citesSessionsByDateWithASourcesLine() {
        guard let answer = subject.answers.last else { return fail("nothing answered yet") }
        expect(!answer.contains("[S"), "the answer still has raw citation tags: \"\(answer)\"")
        expect(answer.range(of: #"\([^)]*\d{4}[^)]*\)"#, options: .regularExpression) != nil,
               "the answer does not cite a session by its date: \"\(answer)\"")
        expect(answer.components(separatedBy: "\n").last?.hasPrefix(Copy.sourcesLead) == true,
               "the answer does not end with a Sources line: \"\(answer)\"")
    }

    func readLineNamesSessionsAndEffort(sessions: Int, _ chosen: Effort) {
        let effort = chosen.setting
        guard let line = subject.notices.first(where: { $0.hasPrefix(Copy.readLead) }) else {
            return fail("no \"Read:\" line under the answer, notices \(subject.notices)")
        }
        expect(line.range(of: "\\b\(sessions) sessions\\b", options: .regularExpression) != nil,
               "the Read line does not say \(sessions) sessions were read: \"\(line)\"")
        expect(line.contains("· \(effort.displayName)"), "the Read line does not give the effort \(effort.displayName): \"\(line)\"")
    }

    /// The older messages stand under the card no longer; only what follows the card is the conversation.
    func showsCompactedCardReplacingEarlier() {
        guard let summary = subject.bubbles.firstIndex(where: { $0.who == .summary }) else {
            return fail("no \"Conversation compacted\" card; it reads \(subject.bubbles.map(\.who))")
        }
        let older = subject.bubbles.prefix(summary).map(\.text)
        expect(older.isEmpty, "the card does not replace the older messages; still shown above it: \(older)")
    }

    func hasInTheBox(_ question: String) {
        expectEqual(subject.questionInBox, question, "the question back in the box")
    }

    func neverAsked(_ question: String) {
        expect(!subject.questions.contains(question), "\"\(question)\" was sent anyway")
    }
}

extension Then where Subject == ShownAlert {
    func isAnAIAlert() { expect(!subject.title.isEmpty, "the alert has no title") }
}

extension Then where Subject == SteeredModel {
    func wasNeverAsked() { expect(subject.requests.isEmpty, "the AI model was asked \(subject.requests.count) time(s)") }
}

@MainActor
extension Then where Subject == PatientChatTab {
    func listsThreadsNewestFirst(_ titles: [String]) {
        expectEqual(subject.threadTitles, titles, "the Chats list, newest first")
    }

    func showsPatientGone() {
        expect(subject.windowShowsPatientGone, "the window still shows the patient instead of \"\(Copy.patientGone)\"")
    }
}

@MainActor
extension Then where Subject == AssistantDesk {
    func keepsEfforts(ask: Effort, patient: Effort, notes: Effort) {
        expectEqual(subject.settings.sessionChatEffort, ask.setting, "the Ask tab's AI effort")
        expectEqual(subject.settings.patientChatEffort, patient.setting, "the patient chat's AI effort")
        expectEqual(subject.settings.noteEffort, notes.setting, "the notes' AI effort")
    }
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

    /// Fails every request as the app does when the built-in model is not downloaded.
    func hasNoModelDownloaded() { answer(with: .fails(LocalLLMEngineError.modelNotDownloaded)) }
}

extension When {
    /// Deletes the patient and everything under it, as the profile's Delete does.
    func removePatient(_ patient: Patient) throws {
        try app.appModel.deletePatient(patient)
    }
}

struct SummaryFailed: LocalizedError {
    var errorDescription: String? { "The summary could not be written." }
}
