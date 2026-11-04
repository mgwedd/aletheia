import Metal
import WhisperEngine
import XCTest
@testable import Aletheia

/// Times Whisper transcription and a llama.cpp generation with the GPU on and
/// off, and checks the output is readable. Run by `.github/workflows/bench-intel.yml`
/// on an Intel runner; skipped unless ALETHEIA_INFERENCE_BENCH is set. Synthetic
/// audio and text only.
///
/// Inputs (environment):
/// - ALETHEIA_BENCH_CLIP: speech audio; ALETHEIA_BENCH_CLIP_TEXT: what it says.
/// - ALETHEIA_BENCH_WHISPER_DIR: folder of `ggml-<model>.bin` files.
/// - ALETHEIA_BENCH_GGUF: the default MedGemma 4B Q4_K_M.
///
/// Each run prints one `BENCH-INFER {json}` line. Only the path the app uses on
/// this Mac (`InferenceCompute.usesGPU`) must be readable; the other is reported.
final class InferenceBenchmarkTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        try XCTSkipUnless(env["ALETHEIA_INFERENCE_BENCH"] != nil, "set ALETHEIA_INFERENCE_BENCH to run")
        let device = MTLCreateSystemDefaultDevice()
        print("BENCH-INFO cpu=\(HardwareCapabilities.current().shortDescription) metal=\(device?.name ?? "none") appleSilicon=\(HardwareCapabilities.current().isAppleSilicon) appUsesGPU=\(InferenceCompute.usesGPU) cpuThreads=\(InferenceCompute.cpuThreads)")
        print("BENCH-INFO ggml \(LlamaEngine.systemInfo)")
    }

    /// The CI Intel runner has AVX2, so the CPU check must say so; this is what
    /// proves the sysctl keys behind it are the right ones.
    func testIntelRunnerHasAVX2() throws {
        let hardware = HardwareCapabilities.current()
        try XCTSkipIf(hardware.isAppleSilicon, "Intel only")
        let keys = HardwareCapabilities.avx2Features.map { "\($0)=\(HardwareCapabilities.sysctlInt($0).map(String.init) ?? "missing")" }
        print("BENCH-INFO cpu-features \(keys.joined(separator: " "))")
        XCTAssertTrue(hardware.hasAVX2, keys.joined(separator: " "))
        XCTAssertNil(InferenceCompute.unsupportedReason)
    }

    func testWhisper() throws {
        let clip = URL(fileURLWithPath: try XCTUnwrap(env["ALETHEIA_BENCH_CLIP"]))
        let reference = try XCTUnwrap(env["ALETHEIA_BENCH_CLIP_TEXT"])
        let dir = URL(fileURLWithPath: try XCTUnwrap(env["ALETHEIA_BENCH_WHISPER_DIR"]))
        let samples = try AudioResampler.loadWhisperSamples(from: clip)
        let audioSeconds = Double(samples.count) / 16_000
        let models = (env["ALETHEIA_BENCH_WHISPER_MODELS"] ?? "base.en small.en").split(separator: " ").map(String.init)
        for model in models {
            let path = dir.appendingPathComponent("ggml-\(model).bin")
            guard FileManager.default.fileExists(atPath: path.path) else { print("BENCH-INFO missing \(path.path)"); continue }
            for gpu in [true, false] {
                let clock = ContinuousClock()
                var engine: WhisperEngine?
                let load = clock.measure { engine = try? WhisperEngine(modelPath: path, useGPU: gpu) }
                let loaded = try XCTUnwrap(engine, "\(model) gpu=\(gpu) failed to load")
                var text = ""
                let run = try clock.measure {
                    let threads = gpu ? WhisperEngine.recommendedThreads() : InferenceCompute.cpuThreads
                    text = try loaded.transcribe(samples: samples, threads: threads).map(\.text).joined(separator: " ")
                }
                let wer = Self.wordErrorRate(reference: reference, hypothesis: text)
                let readable = wer < 0.3
                report(["kind": "whisper", "model": model, "gpu": gpu, "load_s": load.seconds, "run_s": run.seconds,
                        "audio_s": audioSeconds, "realtime_factor": run.seconds / audioSeconds,
                        "est_50min_s": run.seconds / audioSeconds * 3000, "wer": wer, "readable": readable, "text": text])
                if gpu == InferenceCompute.usesGPU {
                    XCTAssertTrue(readable, "\(model) gpu=\(gpu): WER \(wer) — \(text)")
                }
            }
        }
    }

    func testLlama() async throws {
        try XCTSkipUnless(LlamaRuntime.isBuilt, "llama runtime not linked")
        let gguf = URL(fileURLWithPath: try XCTUnwrap(env["ALETHEIA_BENCH_GGUF"]))
        // ~500 tokens of synthetic session (the CPU path is slow), then a
        // question with one right answer.
        let filler = (1...20).map { "[\($0 / 2):\(String(format: "%02d", $0 % 2 * 30))] Client: The week was busy with work and errands, and sleep has been uneven." }
        let transcript = (["[0:00] Client: My dog Biscuit has been a comfort since the move."] + filler).joined(separator: "\n")
        let request = LocalLLMRequest(
            system: "You answer questions about a therapy session transcript.",
            prompt: "Transcript:\n\(transcript)\n\nWhat is the name of the client's dog? Then, in two sentences, summarise how the client's week went.",
            sampling: LocalLLMSampling(maxTokens: 64)
        )
        // The CPU path once per thread count in ALETHEIA_BENCH_THREADS (default:
        // the app's own count), to compare physical cores with all threads.
        let threads = (env["ALETHEIA_BENCH_THREADS"] ?? "\(InferenceCompute.cpuThreads)").split(separator: " ").compactMap { Int($0) }
        let runs = [(gpu: true, threads: InferenceCompute.cpuThreads)] + threads.map { (gpu: false, threads: $0) }
        for (gpu, threadCount) in runs {
            let engine = LlamaEngine(modelURL: gguf, sampling: LocalLLMSampling(maxTokens: 64),
                                     budget: ContextBudget(tokens: 4096), usesGPU: gpu, cpuThreads: threadCount)
            let clock = ContinuousClock()
            let load = try await clock.measure { try await engine.load() }
            var text = ""
            let run = try await clock.measure { text = try await engine.generate(request) }
            let stats = engine.lastStats
            let promptTokens = stats?.promptTokens ?? 0
            let promptSeconds = Double(stats?.promptNanos ?? 0) / 1e9
            let outputTokens = stats?.outputTokens ?? 0
            let outputSeconds = Double(stats?.outputNanos ?? 0) / 1e9
            // MedGemma 1.5 may open with a thinking block (`<unused94>thought`)
            // that uses the whole budget, so finding the answer is reported,
            // and only garbled text fails.
            let readable = Self.looksLikeEnglish(Self.withoutSpecialTokens(text))
            let answered = text.contains("Biscuit")
            report(["kind": "llama", "model": "medgemma-1.5-4b-q4_k_m", "gpu": gpu, "threads": gpu ? 0 : threadCount, "load_s": load.seconds, "run_s": run.seconds,
                    "prompt_tokens": promptTokens, "prefill_tps": promptSeconds > 0 ? Double(promptTokens) / promptSeconds : 0,
                    "output_tokens": outputTokens, "decode_tps": outputSeconds > 0 ? Double(outputTokens) / outputSeconds : 0,
                    "readable": readable, "answered": answered, "text": text])
            engine.unload()
            if gpu == InferenceCompute.usesGPU {
                XCTAssertTrue(readable, "gpu=\(gpu) threads=\(threadCount): \(text.debugDescription)")
            }
        }
    }

    // MARK: Helpers

    private func report(_ fields: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        print("BENCH-INFER \(String(decoding: data, as: UTF8.self))")
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Word-level edit distance over the reference length.
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let r = words(reference), h = words(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var previous = Array(0...h.count)
        for i in 1...r.count {
            var current = [i] + Array(repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[h.count]) / Double(r.count)
    }

    /// `text` without `<unusedNN>`-style control tokens.
    static func withoutSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(of: "<[a-z_]+[0-9]*>", with: " ", options: .regularExpression)
    }

    /// Mostly letters and spaces, with real words and no long repeat loop.
    static func looksLikeEnglish(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard scalars.count >= 20 else { return false }
        let plain = scalars.filter { CharacterSet.letters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }.count
        let w = words(text)
        return Double(plain) / Double(scalars.count) > 0.75 && Set(w).count * 2 >= w.count
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
