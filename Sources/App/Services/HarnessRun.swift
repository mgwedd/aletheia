#if DEBUG
import AVFoundation
import Foundation

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
        guard let args = HarnessArgs.parse(ProcessInfo.processInfo.arguments) else { return }
        Task { @MainActor in exit(await run(args)) }
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
            context: .init(patientID: UUID(), patientName: "Harness", patientSlug: "harness", sessionFolder: "harness")
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
