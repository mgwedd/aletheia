import Foundation

/// Why the helper refused or failed a request. Crosses to the app as an NSError
/// carrying `message` as its description.
enum HelperError: Error, Equatable {
    case unknownAsset
    case notAllowed(String)
    case redirectRejected(String)
    case badStatus(Int)
    case badFeed
    case tooLarge
    case transport(String)
    case notConfigured
    case badRevocationList

    var code: Int {
        switch self {
        case .unknownAsset: return 1
        case .notAllowed: return 2
        case .redirectRejected: return 3
        case .badStatus: return 4
        case .badFeed: return 5
        case .tooLarge: return 6
        case .transport: return 7
        case .notConfigured: return 8
        case .badRevocationList: return 9
        }
    }

    var message: String {
        switch self {
        case .unknownAsset: return "The helper doesn't know that download."
        case .notAllowed(let host): return "The helper won't connect to \(host)."
        case .redirectRejected(let host): return "The server redirected somewhere the helper won't go (\(host))."
        case .badStatus(let status): return "The server answered HTTP \(status)."
        case .badFeed: return "The update feed wasn't in the expected format."
        case .tooLarge: return "The response was larger than the helper allows."
        case .transport(let detail): return detail
        case .notConfigured: return "The license revocation list isn't configured yet."
        case .badRevocationList: return "The license revocation list wasn't in the expected format."
        }
    }
}
