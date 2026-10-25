@testable import Aletheia
import Foundation

/// A FileVault answer the test controls.
final class FixtureDisk: DiskEncryptionProbing {
    enum State { case on, off, unknown }
    var state: State = .on

    func isDataVolumeEncrypted(_ url: URL) -> Bool? {
        switch state {
        case .on: return true
        case .off: return false
        case .unknown: return nil
        }
    }
}

/// A clock the test moves by hand.
final class FixtureClock {
    private(set) var now: Date
    init(_ start: Date = Date()) { now = start }
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
