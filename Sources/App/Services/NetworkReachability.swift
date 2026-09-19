import Foundation
import Network

/// A live, read-only snapshot of whether this Mac currently has a usable network
/// path. It exists only to phrase the Settings "Security overview" network line
/// ("online, but nothing but ciphertext leaves" vs "offline; fully functional").
///
/// It observes connectivity with `NWPathMonitor` and sends nothing anywhere — no
/// probe request, no host, no PHI. `isOnline` is `nil` until the first path
/// update arrives, which the posture layer treats as "unknown" and phrases
/// around the standing on-device guarantee rather than a live status.
final class NetworkReachability: ObservableObject {
    /// `true` when a network path is satisfied, `false` when it isn't, and `nil`
    /// before the monitor has reported for the first time.
    @Published private(set) var isOnline: Bool?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.aletheia.reachability")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async { self?.isOnline = online }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
