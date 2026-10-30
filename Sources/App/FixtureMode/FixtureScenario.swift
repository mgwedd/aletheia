#if DEBUG
import Foundation

// Compiled into the Debug app and into the UI-test bundle (see project.yml), so
// the scenario a UI test encodes is the very type the app decodes.

/// The state a UI test asks the app to start in, passed as JSON in the
/// `ALETHEIA_FIXTURE` environment variable of the launched app, for example
/// `{"run":"a1","patients":[{"name":"Jane Doe","sessions":2}],"fileVault":"on"}`.
struct FixtureScenario: Codable, Equatable {
    struct PatientSeed: Codable, Equatable {
        var name: String
        var sessions: Int?
        /// True when the patient has already attested to recording consent.
        var recordingConsent: Bool?
        /// A recorded consent for the patient's first session, so its header
        /// shows the "Consent: verbal, from the patient" line.
        var consentRecorded: Bool?
        /// The first session's transcript, in the stored form
        /// ("[mm:ss] You: …" for the microphone, "[mm:ss] Call audio: …" for the call).
        var transcript: String?
        /// The first session's My Notes.
        var myNotes: String?
        /// The conversation already held on the first session's Ask tab.
        var chat: [ChatSeed]?
        /// The patient's record file overwritten with bytes that aren't JSON,
        /// as a damaged disk or a bad copy leaves it.
        var damaged: Bool?
    }

    struct ChatSeed: Codable, Equatable {
        /// "user", "assistant" or "summary".
        var role: String
        var text: String
    }

    /// A reply the scripted AI gives to any request whose prompt contains
    /// `whenPromptContains`, ahead of the in-order `aiReplies`.
    struct AIRule: Codable, Equatable {
        var whenPromptContains: String
        var reply: String
    }

    /// Names the throwaway data folder and defaults domain. Launching again
    /// with the same run reopens the same data; a new run starts empty.
    var run: String?
    var patients: [PatientSeed]?
    /// "on" (default), "off" or "unknown".
    var fileVault: String?
    /// "dev" (default) or "production".
    var tier: String?
    /// "off" (default) or "on". Off by default: the unlock sheet is the
    /// system's, which a UI test cannot answer, so it would cover the app.
    var appLock: String?
    /// "off" (default), "on" or "test". On counts as a license that lets the
    /// app record and run the AI; test is that and a test license; off is the
    /// unlicensed app.
    var license: String?

    /// Replies the scripted AI engine gives, in order; the last repeats.
    var aiReplies: [String]?
    var aiRules: [AIRule]?
    /// How long each stage of an AI request lasts, so a test can watch the
    /// status line move. Zero or unset: answers at once.
    var aiStageMs: Int?
    /// Streamed requests report reading the prompt in this many parts (one
    /// part, or unset, reports none), then "preparing the answer".
    var aiParts: Int?
    /// Every AI request fails as it does when the model file is not on this Mac.
    var aiModelMissing: Bool?
    /// Streamed replies arrive a word at a time, one word per `aiStageMs`.
    var aiStreamsWords: Bool?
    /// A word-streamed reply stays open after its last word until stopped.
    var aiHoldsOpen: Bool?
    /// The model's reading window in tokens, in place of the Mac's own.
    var contextTokens: Int?
    /// Settings: background summaries start paused, so a note builds its own.
    var summariesPaused: Bool?
    /// Transcription that runs until it is cancelled, so its progress band
    /// stays on screen.
    var slowTranscription: Bool?
    /// Settings > Notes: "concise", "natural" or "detailed".
    var noteLength: String?
    /// AI effort for notes and for Ask: "fast", "normal" or "focus".
    var noteEffort: String?
    var chatEffort: String?

    /// What "Import Audio…" is handed instead of the system open panel:
    /// "clip" (a two-second tone), "twoTracks" (a microphone and a call track,
    /// as Aletheia exports them), "threeFiles" (three tones) or "notAudio" (a
    /// text file named like audio).
    var importFile: String?

    /// The patient whose newest session is on screen at launch, so a test of a
    /// session screen does not depend on finding rows in the sidebar.
    var open: String?

    /// Settings > General > Recording consent: "firstSession" (default) or "everySession".
    var consentPolicy: String?

    /// Overrides the detected Mac memory (in GB) when set, so UI tests can
    /// exercise memory-dependent model choices deterministically.
    var memoryGB: Int?

    /// Overrides the selected built-in Llama model by its raw identifier.
    var llamaModel: String?
    /// Built-in models (raw identifiers) whose weights count as downloaded
    /// when settings first load.
    var downloadedModels: [String]?

    /// Setup was finished and the terms accepted, but no data folder is chosen
    /// on the run's first launch, so the Set up Aletheia sheet is up.
    var noDataFolder: Bool?

    var appLockOn: Bool { appLock == "on" }
    var licenseOn: Bool { license == "on" || license == "test" }
    var testLicense: Bool { license == "test" }

    struct Malformed: Error, CustomStringConvertible {
        let detail: String
        var description: String { "ALETHEIA_FIXTURE is not a valid scenario: \(detail)" }
    }

    /// Reads a scenario. Anything unreadable throws: a typo in a scenario must
    /// stop the run, never silently start the app in some other state.
    static func parse(_ json: String) throws -> FixtureScenario {
        do {
            return try JSONDecoder().decode(FixtureScenario.self, from: Data(json.utf8))
        } catch {
            throw Malformed(detail: String(describing: error))
        }
    }
}
#endif
