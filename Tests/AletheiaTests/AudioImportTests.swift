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

    // MARK: Two tracks

    /// A tone file under `name`, as the user would pick it.
    private func toneFile(named name: String, seconds: Double) throws -> URL {
        let url = base.appendingPathComponent(name)
        try FileManager.default.moveItem(at: try toneFile(seconds: seconds, ext: "caf"), to: url)
        return url
    }

    private func seconds(at url: URL, _ store: Store) throws -> Double {
        let readable = try store.readableRecording(at: url)
        defer { if readable.isTemporary { try? FileManager.default.removeItem(at: readable.url) } }
        return Double(try AudioResampler.loadWhisperSamples(from: readable.url).count) / 16_000
    }

    func testTwoFilesBecomeTheMicrophoneAndCallTracks() throws {
        let protector = FileProtector(key: SymmetricKey(size: .bits256))
        let store = Store(root: root, protector: protector)
        let patient = try store.createPatient(name: "Alex Doe")
        let session = try store.createSession(for: patient)
        let call = try toneFile(named: "Recording - call.caf", seconds: 3)
        let mic = try toneFile(named: "Recording - microphone.caf", seconds: 2)

        try store.importRecordings(from: [call, mic], for: patient, session: session)

        XCTAssertEqual(try seconds(at: store.micRecordingURL(for: patient, session: session), store), 2, accuracy: 0.2)
        XCTAssertEqual(try seconds(at: store.callRecordingURL(for: patient, session: session), store), 3, accuracy: 0.2)
        XCTAssertTrue(scratchIsEmpty(), "no converted copy is left in scratch space")
    }

    func testTheFileNamedCallIsTheCallTrack() throws {
        let a = URL(fileURLWithPath: "/x/Call.caf"), b = URL(fileURLWithPath: "/x/Me.caf")
        XCTAssertEqual(try AudioImport.tracks(for: [a, b]).call, a)
        XCTAssertEqual(try AudioImport.tracks(for: [b, a]).call, a)
        let mic = URL(fileURLWithPath: "/x/mic.caf"), call = URL(fileURLWithPath: "/x/call.caf")
        XCTAssertEqual(try AudioImport.tracks(for: [call, mic]).mic, mic)
    }

    func testWithoutACallNameTheFirstByNameIsTheMicrophone() throws {
        let one = URL(fileURLWithPath: "/x/track 1.wav"), two = URL(fileURLWithPath: "/x/track 2.wav")
        let tracks = try AudioImport.tracks(for: [two, one])
        XCTAssertEqual(tracks.mic, one)
        XCTAssertEqual(tracks.call, two)
    }

    func testThreeFilesAreRefusedAndNothingIsWritten() throws {
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Alex Doe")
        let session = try store.createSession(for: patient)
        let files = try (1...3).map { try toneFile(named: "track \($0).wav", seconds: 1) }

        XCTAssertThrowsError(try store.importRecordings(from: files, for: patient, session: session)) {
            XCTAssertEqual($0 as? AudioImportError, .tooManyFiles)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.micRecordingURL(for: patient, session: session).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.callRecordingURL(for: patient, session: session).path))
    }

    func testWhenOneOfTwoFilesIsNotAudioNothingIsWritten() throws {
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Alex Doe")
        let session = try store.createSession(for: patient)
        let mic = try toneFile(named: "mic.caf", seconds: 1)
        let call = base.appendingPathComponent("call.caf")
        try Data("not audio at all".utf8).write(to: call)

        XCTAssertThrowsError(try store.importRecordings(from: [mic, call], for: patient, session: session)) {
            XCTAssertEqual($0 as? AudioImportError, .unreadable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.micRecordingURL(for: patient, session: session).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.callRecordingURL(for: patient, session: session).path))
        XCTAssertTrue(scratchIsEmpty())
    }
}
