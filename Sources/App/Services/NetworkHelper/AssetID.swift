import Foundation

/// A download the app can ask the network helper for. The raw value is all that
/// crosses to the helper; the helper maps it to a URL from its own table
/// (`HelperAsset`, same raw values — `NetworkHelperCatalogTests` keeps them
/// aligned). Exhaustive switches, so a new pinned model doesn't compile until
/// it has an ID.
enum AssetID: Int, CaseIterable {
    case whisperBaseEn = 1
    case whisperSmallEn = 2
    case whisperMediumEn = 3
    case whisperLargeV3 = 4
    case llama31_8b = 10
    case gemma4_e2b = 11
    /// The release archive named by the update feed.
    case updateArchive = 20

    init(_ model: WhisperModel) {
        switch model {
        case .baseEn: self = .whisperBaseEn
        case .smallEn: self = .whisperSmallEn
        case .mediumEn: self = .whisperMediumEn
        case .largeV3: self = .whisperLargeV3
        }
    }

    init(_ model: LlamaModel) {
        switch model {
        case .llama31_8b: self = .llama31_8b
        case .gemma4_e2b: self = .gemma4_e2b
        }
    }
}
