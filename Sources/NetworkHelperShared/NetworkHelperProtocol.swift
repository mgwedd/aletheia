import Foundation

// The wire contract between the app and its bundled network helper (an XPC
// service). Compiled into BOTH targets; keep it free of anything else.
//
// The helper is the only process with a network entitlement, so the contract is
// deliberately narrow: the app names an asset by a small integer, and the
// helper looks the URL up in its own compiled-in table. Nothing the app can say
// is a URL, a string or free-form bytes, so a compromised app cannot point the
// helper at a host of its choosing, and the helper never receives patient data.
// `NetworkHelperSourceTests` asserts that no `String`, `URL` or `Data`
// parameter travels from the app to the helper.

enum NetworkHelperConstants {
    /// CFBundleIdentifier of the XPC service, which is also its service name.
    static let serviceName = "com.aletheia.networkhelper"
    static let errorDomain = "com.aletheia.networkhelper"
}

/// Implemented by the app and handed to the helper with each download, so the
/// helper can report progress back (the reply proxy).
@objc protocol NetworkHelperProgress {
    func report(bytesWritten: Int64, bytesExpected: Int64)
}

/// The helper's whole command set.
@objc protocol NetworkHelperProtocol {
    /// Fetches the update feed (appcast) and replies with its bytes.
    func checkForUpdates(reply: @escaping (Data?, NSError?) -> Void)

    /// Fetches the signed license revocation list and replies with its bytes.
    /// The app verifies the signature; the helper only fetches.
    func fetchRevocations(reply: @escaping (Data?, NSError?) -> Void)

    /// Streams the asset named by `asset` (an `AssetID` raw value) into `file`,
    /// which the app opened write-only in its own container.
    func download(asset: Int, into file: FileHandle, progress: NetworkHelperProgress, reply: @escaping (NSError?) -> Void)
}

enum NetworkHelperInterface {
    /// The interface both ends export / import, with the progress proxy and the
    /// file handle declared so NSXPC will carry them.
    static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: NetworkHelperProtocol.self)
        let download = #selector(NetworkHelperProtocol.download(asset:into:progress:reply:))
        interface.setClasses([FileHandle.self] as NSSet as! Set<AnyHashable>, for: download, argumentIndex: 1, ofReply: false)
        interface.setInterface(NSXPCInterface(with: NetworkHelperProgress.self), for: download, argumentIndex: 2, ofReply: false)
        return interface
    }
}
