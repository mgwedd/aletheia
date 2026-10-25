import XCTest

final class UpdateSpec: AcceptanceCase {
    func test_UPDATE_01() async throws {
        then(when.automaticChecksDefault).isOn("automatic update checks")
        then(when.currentSigningDescription).isNotarizationText()
        then(when.softwareUpdateRows).showVersionNotarizationAndAutomaticSwitch()
    }

    func test_UPDATE_02() async throws {
        let rig = when.updateRig(feed: .sameVersion)
        defer { rig.cleanUp() }

        then(await when.checkManually(rig)).saysUpToDate()
    }

    func test_UPDATE_03() async throws {
        let rig = when.updateRig(feed: .unreachable)
        defer { rig.cleanUp() }

        then(await when.checkManually(rig)).saysCouldNotCheck()
    }

    func test_UPDATE_04() async throws {
        let rig = when.updateRig(feed: .newerRelease)
        defer { rig.cleanUp() }
        await when.checkAutomatically(rig)

        let prompt = when.lookAtPrompt(rig)

        then(prompt).offers(version: "1.1.0")
        then(prompt).hasButtons([Copy.viewDownloads, Copy.skipThisVersion, Copy.remindMeLater, Copy.downloadUpdate])
    }

    func test_UPDATE_05() async throws {
        let rig = when.updateRig(feed: .newerRelease)
        defer { rig.cleanUp() }
        await when.checkAutomatically(rig)

        when.remindLater(rig)
        then(when.lookAtPrompt(rig)).offersNothing()

        await when.checkAutomatically(rig)
        then(when.lookAtPrompt(rig)).offers(version: "1.1.0")
    }

    func test_UPDATE_06() async throws {
        let rig = when.updateRig(feed: .newerRelease)
        defer { rig.cleanUp() }
        await when.checkAutomatically(rig)

        when.skipVersion(rig)
        await when.checkAutomatically(rig)

        then(when.lookAtPrompt(rig)).offersNothing()
    }

    func test_UPDATE_07() async throws {
        let outcome = await when.downloadUpdate(checksumListed: true, checksumMatches: true)
        defer { outcome.rig.cleanUp() }

        then(outcome).downloadedAndOpenedDiskImage()
    }

    func test_UPDATE_08() async throws {
        let outcome = await when.downloadUpdate(checksumListed: true, checksumMatches: false)
        defer { outcome.rig.cleanUp() }

        then(outcome).openedReleasePage()
        then(outcome).deletedTheFile()
    }

    func test_UPDATE_09() async throws {
        let rig = when.updateRig(feed: .newerRelease, interval: nil)
        defer { rig.cleanUp() }

        for _ in 0..<5 { await when.checkAutomatically(rig) }

        then(rig).checkedTheFeed(1)
    }

    func test_UPDATE_10() async throws {
        let outcome = await when.downloadUpdate(checksumListed: false)
        defer { outcome.rig.cleanUp() }

        then(outcome).downloadedNothingAndOpenedReleasePage()
    }
}
