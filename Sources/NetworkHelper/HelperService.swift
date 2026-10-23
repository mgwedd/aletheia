import Foundation

/// The XPC service's implementation of the command set. It holds no state beyond
/// the requests it is running, and never sees anything but an asset number and an open, write-only file.
final class HelperService: NSObject, NetworkHelperProtocol {
    private let fetcher = HelperFetcher()
    /// Cancelled when the app's connection goes away.
    let tasks = HelperTasks()

    func checkForUpdates(reply: @escaping (Data?, NSError?) -> Void) {
        let fetcher = fetcher
        tasks.run {
            do {
                reply(try await fetcher.fetchAppcast(), nil)
            } catch {
                reply(nil, Self.nsError(error))
            }
        }
    }

    func download(asset: Int, into file: FileHandle, progress: NetworkHelperProgress, reply: @escaping (NSError?) -> Void) {
        guard let asset = HelperAsset(rawValue: asset) else {
            try? file.close()
            reply(Self.nsError(HelperError.unknownAsset))
            return
        }
        let fetcher = fetcher
        tasks.run {
            defer { try? file.close() }
            do {
                try await fetcher.download(asset, into: file) { written, expected in
                    progress.report(bytesWritten: written, bytesExpected: expected)
                }
                reply(nil)
            } catch {
                reply(Self.nsError(error))
            }
        }
    }

    private static func nsError(_ error: Error) -> NSError {
        let helperError = (error as? HelperError) ?? .transport(error.localizedDescription)
        return NSError(
            domain: NetworkHelperConstants.errorDomain,
            code: helperError.code,
            userInfo: [NSLocalizedDescriptionKey: helperError.message])
    }
}

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NetworkHelperInterface.make()
        let service = HelperService()
        connection.exportedObject = service
        // The app cancelled, quit or crashed: stop whatever it asked for.
        connection.invalidationHandler = { service.tasks.cancelAll() }
        connection.resume()
        return true
    }
}
