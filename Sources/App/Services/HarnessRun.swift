#if DEBUG
import AVFoundation
import Foundation
import WhisperEngine

/// Debug-only test harness for call-audio recording (driven by scripts/harness.sh):
///   --harness-record <seconds> --out <dir> [--harness-transcribe] [--harness-reference <file>]
/// Records through the same `SessionRecorder` the Record button uses, writes
/// `mic.caf`, `call.caf` and `result.json` into <dir>, then exits. Compiled out of Release.
struct HarnessArgs: Equatable {
    var seconds: Double
    var out: URL
    var transcribe = false
    var reference: URL?

    /// nil when `--harness-record` is absent or its arguments are unusable.
    static func parse(_ argv: [String]) -> HarnessArgs? {
        func value(_ flag: String) -> String? {
            guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
            return argv[i + 1]
        }
        guard let s = value("--harness-record").flatMap(Double.init), s > 0,
              let out = value("--out") else { return nil }
        return HarnessArgs(
            seconds: s,
            out: URL(fileURLWithPath: out, isDirectory: true),
            transcribe: argv.contains("--harness-transcribe"),
            reference: value("--harness-reference").map { URL(fileURLWithPath: $0) }
        )
    }
}

/// Model benchmark on a real recording (driven by scripts/bench-transcription.sh):
///   --harness-bench <audio> --out <dir> [--models large-v3,medium.en,small.en]
///   [--start-min M] [--minutes N] [--harness-download]
/// Transcribes the audio (or an N-minute slice from minute M) with each model
/// through the app's own engine, writes `<model>.txt` transcripts plus
/// `summary.txt` into <dir>, and scores each against the first model (the
/// reference, largest by default) by word error rate. Results are written after
/// every model, so stopping early keeps what finished.
struct HarnessBenchArgs: Equatable {
    var audio: URL
    var out: URL
    var models: [WhisperModel] = [.largeV3, .mediumEn, .smallEn]
    var startMinutes: Double = 0
    var minutes: Double?
    var download = false

    /// nil when `--harness-bench` is absent or its arguments are unusable.
    static func parse(_ argv: [String]) -> HarnessBenchArgs? {
        func value(_ flag: String) -> String? {
            guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
            return argv[i + 1]
        }
        guard let audio = value("--harness-bench"), let out = value("--out") else { return nil }
        var args = HarnessBenchArgs(audio: URL(fileURLWithPath: audio), out: URL(fileURLWithPath: out, isDirectory: true))
        if let list = value("--models") {
            let models = list.split(separator: ",").compactMap { WhisperModel(rawValue: String($0)) }
            guard !models.isEmpty else { return nil }
            args.models = models
        }
        args.startMinutes = value("--start-min").flatMap(Double.init) ?? 0
        args.minutes = value("--minutes").flatMap(Double.init)
        args.download = argv.contains("--harness-download")
        return args
    }

    /// The sample range to transcribe out of `count` 16 kHz samples.
    func sliceRange(count: Int) -> Range<Int> {
        let start = min(count, Int(startMinutes * 60 * 16000))
        guard let minutes else { return start..<count }
        return start..<min(count, start + Int(minutes * 60 * 16000))
    }
}

/// Word-level scoring for the transcripts.
enum HarnessScoring {
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
    }

    /// Strips the `[MM:SS] Source (overlapping):` prefix the transcript formatter adds.
    static func spoken(_ transcript: String) -> String {
        transcript.split(separator: "\n").map { line in
            line.range(of: #"^\[[0-9:]+\][^:]*:"#, options: .regularExpression).map { String(line[$0.upperBound...]) } ?? String(line)
        }.joined(separator: " ")
    }

    /// Word error rate: word-level edit distance / reference word count.
    static func wer(reference: String, hypothesis: String) -> Double {
        let r = words(reference), h = words(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var prev = Array(0...h.count)
        for i in 1...r.count {
            var cur = [i] + Array(repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }

    /// How many distinct reference words also appear in the hypothesis.
    static func sharedWords(reference: String, hypothesis: String) -> Int {
        Set(words(reference)).intersection(words(hypothesis)).count
    }
}

@MainActor
enum HarnessRun {
    static func runIfRequested() {
        let argv = ProcessInfo.processInfo.arguments
        if HarnessEval.runIfRequested(argv: argv) { return }
        if let args = HarnessBenchArgs.parse(argv) {
            Task { @MainActor in exit(await bench(args)) }
        } else if let args = HarnessArgs.parse(argv) {
            Task { @MainActor in exit(await run(args)) }
        }
    }

    private static func bench(_ args: HarnessBenchArgs) async -> Int32 {
        let fm = FileManager.default
        try? fm.createDirectory(at: args.out, withIntermediateDirectories: true)
        var lines: [String] = []
        func log(_ line: String) {
            lines.append(line)
            print(line)
            let summary = args.out.appendingPathComponent("summary.txt")
            try? lines.joined(separator: "\n").appending("\n").write(to: summary, atomically: true, encoding: .utf8)
        }
        let all: [Float]
        do { all = try AudioResampler.loadWhisperSamples(from: args.audio) } catch {
            log("error: couldn't read \(args.audio.lastPathComponent): \(error.localizedDescription)")
            return 1
        }
        let range = args.sliceRange(count: all.count)
        let samples = Array(all[range])
        let audioSeconds = Double(samples.count) / 16000
        log(String(format: "audio %@: %.0fs total, benchmarking %.0fs from %.0fs; whisper.cpp %@",
                   args.audio.lastPathComponent, Double(all.count) / 16000, audioSeconds,
                   Double(range.lowerBound) / 16000, WhisperEngine.version))

        let modelsDir = AppSettings.shared.whisperModelPath.deletingLastPathComponent()
        var reference: (model: WhisperModel, text: String)?
        var failed = false
        for model in args.models {
            let path = modelsDir.appendingPathComponent(model.fileName)
            if !fm.fileExists(atPath: path.path) {
                guard args.download else { log("\(model.rawValue): not downloaded, skipped"); continue }
                log("\(model.rawValue): downloading (~\(model.approximateSizeMB) MB, checksum-verified)…")
                do { try await WhisperModelDownloader().download(model, to: path) } catch {
                    log("\(model.rawValue): download failed: \(error.localizedDescription)"); failed = true; continue
                }
            }
            let start = Date()
            let segments: [WhisperSegment]
            do {
                segments = try await WhisperTranscriber.segments(for: samples, modelPath: path, onProgress: { _ in })
            } catch {
                log("\(model.rawValue): failed: \(error.localizedDescription)"); failed = true; continue
            }
            let seconds = Date().timeIntervalSince(start)
            let text = segments.map(\.text).joined(separator: " ")
            let transcript = segments.map { segment in
                String(format: "[%02d:%02d] %@", Int(segment.start) / 60, Int(segment.start) % 60,
                       segment.text.trimmingCharacters(in: .whitespaces))
            }.joined(separator: "\n")
            let file = args.out.appendingPathComponent("\(model.rawValue).txt")
            try? transcript.write(to: file, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

            var line = String(format: "%@: %.1fs (%.1fx realtime), %d segments, %d words",
                              model.rawValue, seconds, audioSeconds / max(seconds, 0.001),
                              segments.count, HarnessScoring.words(text).count)
            if let reference {
                line += String(format: ", WER vs %@ %.1f%%", reference.model.rawValue,
                               HarnessScoring.wer(reference: reference.text, hypothesis: text) * 100)
            } else {
                reference = (model, text)
                line += " (reference)"
            }
            log(line)
        }
        log("done")
        return failed ? 1 : 0
    }

    private static func run(_ args: HarnessArgs) async -> Int32 {
        var result: [String: Any] = ["requestedSeconds": args.seconds]
        func finish(_ error: String?) -> Int32 {
            if let error {
                result["error"] = error
                FileHandle.standardError.write(Data("harness: \(error)\n".utf8))
            }
            let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: args.out.appendingPathComponent("result.json"))
            return error == nil ? 0 : 1
        }

        try? FileManager.default.createDirectory(at: args.out, withIntermediateDirectories: true)
        let preflight = SystemAudioCapture.checkPermission()
        result["screenCapturePreflightGranted"] = preflight
        // Fail fast: starting without either grant would block on a system dialog.
        guard preflight else {
            return finish("Screen & System Audio Recording not granted to this build (grant it in System Settings, then relaunch).")
        }
        guard MicRecorder.permissionStatus == .authorized else {
            return finish("Microphone access not granted to this build.")
        }

        let micURL = args.out.appendingPathComponent("mic.caf")
        let callURL = args.out.appendingPathComponent("call.caf")
        for url in [micURL, callURL] { try? FileManager.default.removeItem(at: url) }

        let recorder = SessionRecorder()
        await recorder.start(
            micURL: micURL, callURL: callURL,
            context: .init(sessionID: UUID(), patientID: UUID(), patientName: "Harness", patientSlug: "harness", sessionFolder: "harness")
        )
        guard recorder.isRecording else {
            if case .error(let message) = recorder.state { return finish(message) }
            return finish("recorder did not start")
        }
        // Tells scripts/harness.sh to start the far-end audio.
        FileManager.default.createFile(atPath: args.out.appendingPathComponent("recording.started").path, contents: nil)
        try? await Task.sleep(nanoseconds: UInt64(args.seconds * 1_000_000_000))
        let diagnostics = recorder.callAudioDiagnostics()
        await recorder.stop()

        var failure: String?
        var tracks: [String: [String: Any]] = [:]
        for (name, url) in [("mic", micURL), ("call", callURL)] {
            tracks[name] = trackInfo(url)
        }
        tracks["call"]?["buffersReceived"] = diagnostics.buffersReceived
        tracks["call"]?["streamDisrupted"] = diagnostics.streamDisrupted
        tracks["call"]?["lastStart"] = diagnostics.lastStart.label
        if let first = diagnostics.firstFailure {
            tracks["call"]?["error"] = first
            failure = "call audio error: \(first)"
        }
        switch diagnostics.lastStart {
        case .failed, .skipped: failure = failure ?? "call audio did not start: \(diagnostics.lastStart.label)"
        case .started, .notTried: break
        }
        if case .error(let message) = recorder.state { failure = failure ?? message }
        result["tracks"] = tracks

        if args.transcribe { await transcribe(args, micURL: micURL, callURL: callURL, into: &result) }
        return finish(failure)
    }

    private static func trackInfo(_ url: URL) -> [String: Any] {
        var info: [String: Any] = ["file": url.lastPathComponent]
        guard let file = try? AVAudioFile(forReading: url) else { return info }
        info["bytes"] = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        info["durationSeconds"] = Double(file.length) / file.processingFormat.sampleRate
        if let samples = try? AudioResampler.loadWhisperSamples(from: url), !samples.isEmpty {
            info["peak"] = Double(samples.map { abs($0) }.max() ?? 0)
            info["rms"] = (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
            info["silent"] = AudioResampler.isEssentiallySilent(samples)
        }
        return info
    }

    private static func transcribe(_ args: HarnessArgs, micURL: URL, callURL: URL, into result: inout [String: Any]) async {
        let transcriber = WhisperTranscriber(modelPath: AppSettings.shared.whisperModelPath)
        guard transcriber.isReady else { result["transcription"] = "model missing"; return }
        let reference = args.reference.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        var out: [String: Any] = [:]
        var texts: [String: String] = [:]
        for (name, url) in [("mic", micURL), ("call", callURL)] {
            let raw = (try? await transcriber.transcribeSession(
                micURL: name == "mic" ? url : nil, callURL: name == "call" ? url : nil, onProgress: { _ in })) ?? ""
            texts[name] = HarnessScoring.spoken(raw)
            try? raw.write(to: args.out.appendingPathComponent("\(name)-track.txt"), atomically: true, encoding: .utf8)
        }
        if let reference {
            out["callWER"] = HarnessScoring.wer(reference: reference, hypothesis: texts["call"] ?? "")
            out["micLeakedReferenceWords"] = HarnessScoring.sharedWords(reference: reference, hypothesis: texts["mic"] ?? "")
            out["referenceDistinctWords"] = Set(HarnessScoring.words(reference)).count
        }
        result["transcription"] = out
    }
}
#endif
