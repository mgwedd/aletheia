import Foundation

/// Reads whether the volume holding the data folder is encrypted. Behind a
/// protocol so tests inject a fake.
protocol DiskEncryptionProbing {
    /// True/false when macOS reports the volume's encryption state; nil when it
    /// can't be read.
    func isDataVolumeEncrypted(_ url: URL) -> Bool?
}

/// The one system read the probe depends on, split out so tests can fake it.
protocol VolumeResourceProviding {
    func volumeIsEncrypted(at url: URL) -> Bool?
}

/// Asks the file system through `URLResourceKey.volumeIsEncryptedKey`. This is
/// an in-process read: it works under the App Sandbox and starts no subprocess.
struct SystemVolumeResources: VolumeResourceProviding {
    func volumeIsEncrypted(at url: URL) -> Bool? {
        guard let values = try? url.resourceValues(forKeys: [.volumeIsEncryptedKey]) else { return nil }
        return values.volumeIsEncrypted
    }
}

struct DiskEncryptionProbe: DiskEncryptionProbing {
    var resources: VolumeResourceProviding = SystemVolumeResources()

    func isDataVolumeEncrypted(_ url: URL) -> Bool? {
        resources.volumeIsEncrypted(at: url)
    }
}

/// Whether new patient information may be entered, given the disk state.
/// Pure. Only a disk known to be unencrypted blocks; an unknown state allows
/// entry (with a warning) so nobody is locked out by a failed read. Reading and
/// exporting existing data is never gated.
enum PHIEntryGate {
    static func allowsNewPHI(diskEncrypted: Bool?) -> Bool {
        diskEncrypted != false
    }

    /// True when entry is allowed but the disk state couldn't be confirmed.
    static func warnsUnknown(diskEncrypted: Bool?) -> Bool {
        diskEncrypted == nil
    }

    static let blockedTitle = "Turn on FileVault"
    static let blockedMessage = "FileVault is off for this Mac's disk, so Aletheia can't add new patients, sessions or recordings yet. Turn on FileVault in System Settings, then come back. Your existing records stay readable and can be exported."
    static let unknownTitle = "Couldn't confirm disk encryption"
    static let unknownMessage = "Aletheia couldn't tell whether this Mac's disk is encrypted. You can continue, but check that FileVault is on in System Settings."
}
