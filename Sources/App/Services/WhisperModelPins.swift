import Foundation

/// Where the Whisper models come from and the SHA-256 each must match.
///
/// There is no unpinned model: `expectedSHA256` is a non-optional `String`
/// switched exhaustively over every case (no `default`), so adding a model
/// without a pin doesn't compile, and `WhisperModelDownloader` always verifies
/// the finished download against it before accepting the file.
///
/// The pins are only meaningful for the exact bytes they were computed from, so
/// downloads are locked to an immutable Hugging Face commit (`revision`) rather
/// than a moving branch.
///
/// Don't edit these by hand or from memory. `scripts/verify-model-pins.sh`
/// (run by the "Verify Model Pins" workflow on any change here, and weekly)
/// downloads each model at `revision` and requires the bytes, the Hugging Face
/// LFS oid, and the SHA-1 in whisper.cpp's README to all agree with the pin. To
/// bump a model or revision, run `scripts/verify-model-pins.sh --print` on a
/// runner to get the current values, then paste them here. The script parses this
/// file strictly, so keep the layout exactly as it is.
extension WhisperModel {
    /// Hugging Face commit of `ggerganov/whisper.cpp` the pins below were computed at.
    static let revision = "5359861c739e955e79d9a303bcbc70fb988958b1"

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(Self.revision)/ggml-\(rawValue).bin")!
    }

    /// SHA-256 (lowercase hex) of `ggml-<rawValue>.bin` at `revision`.
    var expectedSHA256: String {
        switch self {
        case .baseEn: return "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
        case .smallEn: return "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"
        case .mediumEn: return "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356"
        case .largeV3: return "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"
        }
    }
}
