import XCTest

final class SearchSpec: AcceptanceCase {
    func test_SEARCH_01() async throws {
        try pending("UI driver: the command-F shortcut moving focus to the sidebar field is a window responder-chain effect with no seam")
    }

    func test_SEARCH_02() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        try given.session(for: jane, on: searchDay(2026, 3, 4), transcript: "We talked about the anxiety around travel.")

        let box = try await when.typeInSearch("anxiety")

        then(box).showsResultsOverThePage(including: "Transcripts")
    }

    func test_SEARCH_03() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        let session = try given.session(for: jane, on: searchDay(2026, 3, 4), transcript: "Mentioned the harbor several times.")
        given.myNotes("Harbor came up again.", on: session)
        try given.progressNote("Harbor imagery is recurring.", for: jane, on: session)
        given.comment("Ask about the harbor.", on: "Mentioned the harbor", at: 0, in: session)
        _ = try await given.patient(named: "Harbor Smith")

        let box = try await when.typeInSearch("harbor")

        then(box).groupsAre(Copy.searchGroups)
        then(box).highlightsTheMatch(of: "harbor", in: Copy.searchGroups)
    }

    func test_SEARCH_04() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        for day in 1...7 {
            try given.session(for: jane, on: searchDay(2026, 3, day), transcript: "Session \(day) touched on the river.")
        }

        let box = try await when.typeInSearch("river")

        then(box).showsOnly(5, of: 7, in: "Transcripts")
        then(box).offersShowMore(2, in: "Transcripts")

        await when.pressReturnOnShowMore(of: "Transcripts", in: box)

        then(box).showsOnly(7, of: 7, in: "Transcripts")
        then(box).offersNoMoreIn("Transcripts")
    }

    func test_SEARCH_05() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        try given.session(for: jane, on: searchDay(2026, 3, 4), transcript: "The lighthouse again.")
        try given.session(for: jane, on: searchDay(2026, 3, 5), transcript: "The lighthouse once more.")

        let box = try await when.typeInSearch("lighthouse")
        when.pressDown(in: box)

        then(box).hasSelectedTheSecondResult()
        let opened = try when.pressReturn(in: box)
        XCTAssertNotNil(opened, "Return on a result did not open it")

        when.pressEscape(in: box)

        then(box).isCleared()
    }

    func test_SEARCH_06() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        let session = try given.session(
            for: jane, on: searchDay(2026, 3, 4),
            transcript: "Opening small talk.\nMore small talk.\nThen the bakery came up.\nClosing words.")

        let box = try await when.typeInSearch("bakery")
        let opened = try XCTUnwrap(try when.pressReturn(in: box), "no result to open")

        then(opened).opensTheTranscriptOf(session)
        then(opened).scrollsToAndMarks("bakery", onLineContaining: "Then the bakery came up.")
    }

    func test_SEARCH_07() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        let weak = try given.session(for: jane, on: searchDay(2026, 3, 4), transcript: "Mentioned therapy once in passing.")
        let strong = try given.session(for: jane, on: searchDay(2026, 3, 5), transcript: "Therapy, therapy, therapy: all about therapy goals.")

        let box = try await when.typeInSearch("thera")

        then(box).includesTranscriptOf(weak)
        then(box).includesTranscriptOf(strong)
        then(box).listsSessions(onDays: [searchDay(2026, 3, 5), searchDay(2026, 3, 4)])
    }

    func test_SEARCH_08() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        try given.session(for: jane, on: searchDay(2026, 3, 4), transcript: "Ordinary words only.")

        let box = try await when.typeInSearch("zzzqqq")

        then(box).saysNoResults()
    }

    func test_SEARCH_09() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        let hold = await given.searchIndexIsBusy()
        let session = try given.session(for: jane, on: searchDay(2026, 3, 4), transcript: "The orchard was quiet.")

        let early = try await when.typeInSearchRightAway("orchard")
        then(early).warnsResultsMayBeIncomplete()

        hold.release()
        await when.waitForSearchToCatchUp()
        await when.resultsRefresh(early)

        then(early).hasNoWarning()
        then(early).includesTranscriptOf(session)
    }

    func test_SEARCH_10() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        let session = try given.session(for: jane, on: searchDay(2026, 3, 4), transcript: "The glacier trip was mentioned.")
        await when.waitForSearchToCatchUp()

        await when.quitDeleteTheSearchFileAndReopen()
        await when.waitForSearchToCatchUp()
        let box = try await when.typeInSearch("glacier")

        then(box).includesTranscriptOf(session)
    }

    func test_SEARCH_11() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        try given.session(for: jane, on: searchDay(2026, 3, 4), transcript: "The meadow was discussed.")
        await when.waitForSearchToCatchUp()

        let locked = when.lockTheApp()
        then(try when.searchWhileLocked(for: "meadow")).findsNothing()

        await when.unlock(locked)
        let box = try await when.typeInSearch("meadow")

        then(box).showsResultsOverThePage(including: "Transcripts")
    }

    func test_SEARCH_12() async throws {
        given.buildIs(.dev)
        _ = try await given.patient(named: "Jane Doe")

        let listing = when.turnOnFindPatientsInSpotlight()

        then(listing).listsPatientsByInitialsOnly(hiding: ["Jane", "Doe"])
    }

    func test_SEARCH_13() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        try given.session(for: jane, on: searchDay(2026, 3, 4), transcript: "She enjoyed the Café near the station.")

        let upper = try await when.typeInSearch("CAFÉ")
        let lower = try await when.typeInSearch("café")
        let plain = try await when.typeInSearch("cafe")

        then(upper).givesTheSameResultsAs(lower)
        then(plain).givesTheSameResultsAs(lower)
    }

    func test_SEARCH_14() async throws {
        let joanne = try await given.patient(named: "Joanne Fields")
        let other = try await given.patient(named: "Bill Reed")
        let march = try given.session(for: joanne, on: searchDay(2026, 3, 4), transcript: "We discussed grief and loss.")
        try given.session(for: joanne, on: searchDay(2026, 5, 6), transcript: "We discussed grief again.")
        try given.session(for: joanne, on: searchDay(2026, 5, 20), transcript: "Mostly small talk.")
        try given.session(for: other, on: searchDay(2026, 3, 4), transcript: "We discussed grief too.")

        let withTopic = try await when.typeInSearch("Joanne grief")
        then(withTopic).onlyShowSessions(of: joanne)
        then(withTopic).listsSessions(onDays: [searchDay(2026, 5, 6), searchDay(2026, 3, 4)])

        let narrowed = try await when.typeInSearch("Joanne grief March")
        then(narrowed).onlyShowSessions(of: joanne)
        then(narrowed).includesTranscriptOf(march)
        then(narrowed).listsSessions(onDays: [searchDay(2026, 3, 4)])
    }

    func test_SEARCH_15() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        try given.session(for: jane, on: searchDay(2026, 3, 4), transcript: "The vineyard was lovely.")
        await when.waitForSearchToCatchUp()

        try when.deleteWithAllRecords(jane)
        await when.waitForSearchToCatchUp()
        let box = try await when.typeInSearch("vineyard")

        then(box).mentionNobodyNamed("Jane Doe")
    }
}
