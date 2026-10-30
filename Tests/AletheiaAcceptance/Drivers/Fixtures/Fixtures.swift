@testable import Aletheia
import Foundation

/// The test's clock, starting at the real now, or at one in the morning when
/// the run is in the first hour of a day, so "a few minutes ago" is still
/// today. Kept in this module (not the app's `FixtureClock`) because spec
/// files read it without importing the app.
final class TestClock {
    private(set) var now: Date
    init(_ start: Date = TestClock.awayFromMidnight(Date())) { now = start }
    static func awayFromMidnight(_ date: Date) -> Date {
        let oneAM = Calendar.current.startOfDay(for: date).addingTimeInterval(3600)
        return max(date, oneAM)
    }
    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Keeps Spotlight untouched.
struct SilentSpotlight: SpotlightIndexing {
    func replaceIndex(with entries: [SpotlightEntry]) {}
    func clear() {}
}

/// A local model that answers from a script, in order.
final class ScriptedLLMEngine: LocalLLMEngine {
    var state: LocalLLMEngineState = .notLoaded
    private var replies: [String]
    private(set) var requests: [LocalLLMRequest] = []

    init(replies: [String] = []) { self.replies = replies }

    func load() async throws { state = .notLoaded }
    func unload() {}

    func generate(_ request: LocalLLMRequest) async throws -> String {
        requests.append(request)
        return replies.isEmpty ? "" : replies.removeFirst()
    }
}

/// A transcriber that returns a fixed transcript without touching audio.
struct FixtureTranscriber: Transcribing {
    var transcript: String
    var isReady: Bool { true }

    func transcribeSession(
        micURL: URL?, callURL: URL?, onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> String { transcript }
}
