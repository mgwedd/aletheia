import AVFoundation
import CryptoKit
import XCTest
@testable import Aletheia

/// Importing an audio file gives the session a recording the transcriber can
/// read, sealed when encryption is on, without touching the original file or
/// replacing a recording the session already has.
final class AudioImportTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var originalScratch: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioImportTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Data", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        originalScratch = PrivateStaging.root
        PrivateStaging.root = base.appendingPathComponent("Scratch", isDirectory: true)
    }

    override func tearDownWithError() throws {
        PrivateStaging.root = originalScratch
        try? FileManager.default.removeItem(at: base)
    }

    /// A tone file in the format the user might pick (e.g. a WAV from a phone).
    private func toneFile(seconds: Double = 2, rate: Double = 44_100, channels: AVAudioChannelCount = 1, ext: String = "wav") throws -> URL {
        let url = base.appendingPathComponent("picked-\(UUID().uuidString).\(ext)")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false))
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                data[channel][frame] = 0.3 * sin(2 * .pi * 440 * Float(frame) / Float(rate))
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        return url
    }

    private func scratchIsEmpty() -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: PrivateStaging.root.path)) ?? []).isEmpty
    }

    func testAnImportedFileBecomesATranscribableRecordingAndTheOriginalIsKept() throws {
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Alex Doe")
        let session = try store.createSession(for: patient)
        let picked = try toneFile(seconds: 2)
        let original = try Data(contentsOf: picked)

        try store.importRecording(from: picked, for: patient, session: session)

        let mic = store.micRecordingURL(for: patient, session: session)
        let samples = try AudioResampler.loadWhisperSamples(from: mic)
        XCTAssertEqual(Double(samples.count), 32_000, accuracy: 3_200, "about two seconds at 16 kHz")
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.1, "the sound came through")
        XCTAssertEqual(try Data(contentsOf: picked), original, "the picked file is only read")
        XCTAssertTrue(scratchIsEmpty(), "no converted copy is left in scratch space")
    }

    func testTheImportIsSealedWhenEncryptionIsOn() throws {
        let protector = FileProtector(key: SymmetricKey(size: .bits256))
        let store = Store(root: root, protector: protector)
        let patient = try store.createPatient(name: "Alex Doe")
        let session = try store.createSession(for: patient)

        try store.importRecording(from: try toneFile(), for: patient, session: session)

        let mic = store.micRecordingURL(for: patient, session: session)
        XCTAssertTrue(ChunkedCipher.isEnvelope(fileAt: mic), "the recording is ciphertext at rest")
        let readable = try store.readableRecording(at: mic)
        defer { if readable.isTemporary { try? FileManager.default.removeItem(at: readable.url) } }
        XCTAssertFalse(try AudioResampler.loadWhisperSamples(from: readable.url).isEmpty)
    }

    func testStereoAndHighSampleRateFilesImport() throws {
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Alex Doe")
        for (rate, channels) in [(48_000.0, AVAudioChannelCount(2)), (96_000.0, AVAudioChannelCount(1))] {
            let session = try store.createSession(for: patient, on: Date(timeIntervalSinceNow: -rate))
            try store.importRecording(from: try toneFile(seconds: 1, rate: rate, channels: channels), for: patient, session: session)
            let samples = try AudioResampler.loadWhisperSamples(from: store.micRecordingURL(for: patient, session: session))
            XCTAssertEqual(Double(samples.count), 16_000, accuracy: 1_600, "\(rate) Hz, \(channels) channel(s)")
        }
    }

    func testAFileThatIsNotAudioIsRefusedAndNothingIsWritten() throws {
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Alex Doe")
        let session = try store.createSession(for: patient)
        let notAudio = base.appendingPathComponent("notes.m4a")
        try Data("not audio at all".utf8).write(to: notAudio)

        XCTAssertThrowsError(try store.importRecording(from: notAudio, for: patient, session: session)) {
            XCTAssertEqual($0 as? AudioImportError, .unreadable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.micRecordingURL(for: patient, session: session).path))
        XCTAssertTrue(scratchIsEmpty())
    }

    func testAnExistingRecordingIsNeverReplaced() throws {
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Alex Doe")
        let session = try store.createSession(for: patient)
        let mic = store.micRecordingURL(for: patient, session: session)
        try Data("recorded in the app".utf8).write(to: mic)

        XCTAssertThrowsError(try store.importRecording(from: try toneFile(), for: patient, session: session)) {
            XCTAssertEqual($0 as? AudioImportError, .sessionHasRecording)
        }
        XCTAssertEqual(try Data(contentsOf: mic), Data("recorded in the app".utf8))
    }

    func testASessionWithASignedNoteIsRefused() throws {
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Alex Doe")
        let session = try store.createSession(for: patient)
        try store.saveGeneratedNote("S: calm", for: patient, session: session, format: .soap)
        try store.signNote(for: patient, session: session, format: .soap, signer: "mw:501")

        XCTAssertThrowsError(try store.importRecording(from: try toneFile(), for: patient, session: session))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.micRecordingURL(for: patient, session: session).path))
    }

    func testTheImportIsRecordedInTheActivityLog() throws {
        let store = Store(root: root)
        var entries: [(AuditAction, String?)] = []
        store.onAudit = { action, subject, _ in entries.append((action, subject)) }
        let patient = try store.createPatient(name: "Alex Doe")
        let session = try store.createSession(for: patient)
        entries.removeAll()

        try store.importRecording(from: try toneFile(), for: patient, session: session)

        XCTAssertEqual(entries.map(\.0), [.phiCreated])
        XCTAssertEqual(entries.first?.1, session.id.uuidString)
    }
}
