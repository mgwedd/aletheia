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

// MARK: - Chats list width

/// The patient chat window's Chats list before and after its edge was dragged.
struct ChatsListDrag {
    let windowWidth: CGFloat
    let before: CGFloat
    let after: CGFloat
    let narrowest: CGFloat
    let widest: CGFloat
    let chatMinimum: CGFloat
    var chatAfter: CGFloat { windowWidth - after - 1 }
}

extension When {
    /// The chat window as it usually opens, wider than its 640-point minimum.
    static let chatWindowWidth: CGFloat = 900

    func dragChatsListEdge(by points: CGFloat, windowWidth: CGFloat = When.chatWindowWidth) -> ChatsListDrag {
        let before = ChatThreadsLayout.idealWidth
        return ChatsListDrag(
            windowWidth: windowWidth,
            before: before,
            after: ChatThreadsLayout.width(proposed: before + points, total: windowWidth),
            narrowest: ChatThreadsLayout.minWidth,
            widest: ChatThreadsLayout.maxWidth,
            chatMinimum: ChatThreadsLayout.chatMinWidth)
    }
}

extension Then where Subject == ChatsListDrag {
    func movesTheListBy(_ points: CGFloat) {
        expectEqual(subject.after - subject.before, points, "how far the Chats list's edge moved")
    }

    func staysUsable() {
        expect(subject.after >= subject.narrowest, "the Chats list narrowed to \(subject.after), under \(subject.narrowest)")
        expect(subject.after <= subject.widest, "the Chats list widened to \(subject.after), over \(subject.widest)")
        expect(subject.narrowest >= 180, "the Chats list's narrowest width \(subject.narrowest) cuts off chat titles")
        expect(subject.chatAfter >= subject.chatMinimum,
               "the chat narrowed to \(subject.chatAfter), under its \(subject.chatMinimum)")
    }
}

// MARK: - Depth

extension Then where Subject == DepthControl {
    func offersTheDepths() {
        expectEqual(subject.label, Copy.depthLabel, "what the Ask bar's depth control is called")
        expectEqual(subject.depths, Copy.depthChoices, "what the Ask bar's Depth offers")
    }

    func hasChosen(_ depth: Depth) {
        expectEqual(subject.chosen, depth.setting, "the depth picked on the Ask bar")
    }

    /// The Notes Depth menu and the Ask bar's Depth go by one name and offer the same choices.
    func matchesTheNoteMenu(_ menu: DepthMenu) {
        expect(menu.label.hasPrefix("\(subject.label):"),
               "the note button \"\(menu.label)\" is not called \(subject.label)")
        expectEqual(menu.depths, subject.depths, "the note Depth menu's choices against the Ask bar's")
    }
}

@MainActor
extension Then where Subject == AssistantDesk {
    func keepsAskDepthSetting(_ depth: Depth) {
        expectEqual(subject.askDepthSetting, depth.setting, "Settings → Ask depth")
    }
}

extension SteeredModel {
    /// The requests that answered an Ask question, oldest first.
    var askRequests: [LocalLLMRequest] { requests.filter { $0.prompt.contains(Copy.questionLead) } }
    /// The requests that wrote a note, oldest first.
    var noteRequests: [LocalLLMRequest] { requests.filter { ($0.system + $0.prompt).contains(Copy.noteFormatStillApplies) } }
}

extension Then where Subject == SteeredModel {
    /// The latest answer was asked for at `depth`, as guidance only: the depth's
    /// target and form, the shared clarity rule, and no other depth's guidance.
    func wasAskedToAnswer(at depth: Depth) {
        guard let request = subject.askRequests.last else { return fail("no question reached the AI model") }
        let level = depth.setting
        expect(request.system.contains(Copy.askTarget(depth)),
               "the answer was not asked for \"\(Copy.askTarget(depth))\"")
        expect(request.system.contains(level.guidance(for: .answer)), "the answer was not asked for at \(level.displayName)")
        expect(request.system.contains(AnswerDepth.clarityRule), "the answer was not given the clarity rule")
        for other in AnswerDepth.allCases where other != level {
            expect(!request.system.contains(other.guidance(for: .answer)), "the answer was also asked for at \(other.displayName)")
        }
    }

    /// Every depth is sent with the same length limit: depth shapes the prompt, never cuts the answer.
    func capsEveryDepthAlike() {
        let caps = Set(subject.askRequests.map(\.sampling.maxTokens))
        expect(subject.askRequests.count > 1, "fewer than two answers to compare")
        expectEqual(caps.count, 1, "different length limits across depths: \(caps)")
    }

    /// The latest answer was told to take its question on its own terms, with the question read last.
    func wasToldToAnswerOnItsOwnTerms(_ question: String, after earlier: String) {
        guard let request = subject.askRequests.last else { return fail("no question reached the AI model") }
        expect(request.system.contains(Copy.onItsOwnTerms), "the answer was not told to answer the latest question on its own terms")
        expect(request.system.contains(Copy.earlierTurnsAsContext), "the answer was not told to use earlier turns only as context")
        expect(request.prompt.hasSuffix("\(Copy.questionLead) \(question)"),
               "the latest question is not the last thing the model reads: \"…\(request.prompt.suffix(120))\"")
        let inTurns = request.turns.contains { $0.text.contains(earlier) }
        let beforeQuestion: Bool = {
            guard let found = request.prompt.range(of: earlier),
                  let asked = request.prompt.range(of: question, options: .backwards) else { return false }
            return found.lowerBound < asked.lowerBound
        }()
        expect(inTurns || beforeQuestion, "the earlier exchange \"\(earlier)\" is not ahead of the latest question")
    }

    /// The last note and the last answer were both asked for at `depth`, from the same wording.
    func gaveNoteAndAnswerTheSameKindOfLimit(_ depth: Depth) {
        guard let note = subject.noteRequests.last else { return fail("no note reached the AI model") }
        guard let answer = subject.askRequests.last else { return fail("no question reached the AI model") }
        let level = depth.setting
        for (what, text) in [("note", note.system + note.prompt), ("answer", answer.system + answer.prompt)] {
            expect(text.contains("Depth: \(level.rawValue). "), "the \(what) was not asked for at \(level.displayName)")
            expect(text.contains(level.form), "the \(what) was not given \(level.displayName)'s form")
            expect(text.contains(AnswerDepth.clarityRule), "the \(what) was not given the clarity rule")
        }
    }
}
