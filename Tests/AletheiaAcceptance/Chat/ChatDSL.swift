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

    func selectsAcrossTheAnswer(_ pieces: [String]) {
        let runs = subject.selectableRunsOfLastAnswer
        expect(runs.contains { run in pieces.allSatisfy { run.contains($0) } },
               "no single selectable run holds \(pieces); runs: \(runs)")
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

    func isEmpty() { expect(subject.bubbles.isEmpty, "the conversation still shows \(subject.bubbles)") }

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

    func showsNoReadLine() {
        expect(!subject.notices.contains { $0.hasPrefix(Copy.readLead) }, "a \"Read:\" line is still under the answer: \(subject.notices)")
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

    /// No answer or summary shows a model's reasoning or one of its internal markers.
    func showsNoReasoningOrMarkers() {
        let shown = subject.bubbles.filter { $0.who != .you }.map(\.text)
        expect(!shown.isEmpty, "nothing is shown to check")
        for text in shown {
            expect(!ModelMarkers.appear(in: text), "an answer shows the model's reasoning or markers: \"\(text)\"")
        }
    }

    func showsSummary(_ text: String) {
        expect(subject.bubbles.contains { $0.who == .summary && $0.text == text },
               "no \"Conversation compacted\" card reading \"\(text)\"; it reads \(subject.bubbles)")
    }

    /// The `earlier` questions and answers are all still shown, with the card after them.
    func showsTheCardBelowTheAnswers(_ earlier: Int) {
        guard let card = subject.bubbles.firstIndex(where: { $0.who == .summary }) else {
            return fail("no \"Conversation compacted\" card yet; it reads \(subject.bubbles.map(\.who))")
        }
        expectEqual(card, earlier, "how many messages stand above the card")
    }

    /// Nothing changed in the conversation: the same messages, and no card.
    func isAsItWas(_ before: AskPane) {
        expectEqual(subject.bubbles, before.bubbles, "the conversation after the summary failed")
        hasNotCompacted()
    }
}

extension Then where Subject == ShownAlert {
    func saysTheSummaryDidNotFinish() {
        expectEqual(subject.message, Copy.summaryDidNotFinish, "what the alert says")
    }
}

/// A model's reasoning and its internal markers, as a reply saved by an earlier version held them.
enum ModelMarkers {
    /// `answer` with its reasoning in front and a marker after it.
    static func reply(_ answer: String) -> String {
        Copy.reasoningOpen + Copy.hiddenReasoning + Copy.reasoningClose + answer + Copy.endOfTurn
    }

    static func appear(in text: String) -> Bool {
        text.contains("<unused") || text.contains("<end_of_turn>") || text.contains("<start_of_turn>")
            || text.contains(Copy.hiddenReasoning)
    }
}

extension Then where Subject == ShownAlert {
    func isAnAIAlert() { expect(!subject.title.isEmpty, "the alert has no title") }
}

extension Then where Subject == SteeredModel {
    func wasNeverAsked() { expect(subject.requests.isEmpty, "the AI model was asked \(subject.requests.count) time(s)") }

    /// Nothing the model was sent holds a reasoning span or a marker, in its instructions, turns or question.
    func wasSentNoReasoningOrMarkers() {
        expect(!subject.requests.isEmpty, "the AI model was never asked")
        for request in subject.requests {
            let sent = [request.system, request.prompt] + request.turns.map(\.text)
            for text in sent {
                expect(!ModelMarkers.appear(in: text), "the model was sent reasoning or markers: \"\(text.suffix(200))\"")
            }
        }
    }

    /// The model was asked to summarize the conversation, and sent the earlier answers.
    func wasAskedToSummarize() {
        expect(subject.requests.contains { $0.prompt.contains(Copy.summaryRequest) }, "the model was never asked to summarize")
    }
}

@MainActor
extension Then where Subject == PatientChatTab {
    func listsThreadsNewestFirst(_ titles: [String]) {
        expectEqual(subject.threadTitles, titles, "the Chats list, newest first")
    }

    func listsNoThreads() { expect(subject.threadTitles.isEmpty, "the Chats list still lists \(subject.threadTitles)") }

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

    /// Asked to summarize a conversation, it writes `text` and goes on writing,
    /// until `moveOn()`.
    func summarizesConversationSlowly(as text: String) {
        answer(Copy.summaryRequest, with: .writesThenWaits(text))
    }

    /// Asked to summarize a conversation, it writes `text` and is still writing when
    /// it reaches the most a reply may be.
    func runsOutOfRoomSummarizing(after text: String) {
        answer(Copy.summaryRequest, with: .writes(text))
        stopsAtTheReplyLimit(whenAsked: Copy.summaryRequest, after: AITask.compaction.maxTokens)
    }
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
        expect(request.prompt.hasSuffix("\n\(Copy.questionLead) \(question)") && !request.prompt.contains(earlier),
               "the latest question is not on its own after the material and earlier turns: \"\(request.prompt.prefix(120))…\"")
        expect(request.turns.contains { $0.text.contains(earlier) },
               "the earlier exchange \"\(earlier)\" is not in the turns ahead of the latest question")
    }

    /// The latest answer's depth was the last thing the model read before the question.
    func remindedOfTheDepthNextToTheQuestion(_ depth: Depth, _ question: String) {
        guard let request = subject.askRequests.last else { return fail("no question reached the AI model") }
        let lines = request.prompt.components(separatedBy: "\n")
        expectEqual(lines.last, "\(Copy.questionLead) \(question)", "the question is not the last line of the final turn")
        let reminder = lines.dropLast().last ?? ""
        expect(reminder.hasPrefix("Depth: \(depth.setting.rawValue). ") && reminder.contains(Copy.askTarget(depth)),
               "the line before the question does not give the depth: \"\(reminder)\"")
    }

    /// The latest answer was told to write to the user as "you", say each
    /// point once, add no unasked action items, and keep a thin session short.
    func wasToldToWriteToYouOnceAndOnlyWhatWasAgreed() {
        guard let request = subject.askRequests.last else { return fail("no question reached the AI model") }
        for rule in [Copy.writeToYou, Copy.sayEachPointOnce, Copy.noSecondList, Copy.noUnaskedActionItems, Copy.thinSessionShortAnswer] {
            expect(request.system.contains(rule), "the answer was not told \"\(rule)\"")
        }
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
