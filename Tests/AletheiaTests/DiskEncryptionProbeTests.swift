import XCTest
@testable import Aletheia

final class DiskEncryptionProbeTests: XCTestCase {
    private struct FakeResources: VolumeResourceProviding {
        var value: Bool?
        func volumeIsEncrypted(at url: URL) -> Bool? { value }
    }

    private let url = URL(fileURLWithPath: "/tmp/data")

    func testReportsEncryptedVolume() {
        let probe = DiskEncryptionProbe(resources: FakeResources(value: true))
        XCTAssertEqual(probe.isDataVolumeEncrypted(url), true)
    }

    func testReportsUnencryptedVolume() {
        let probe = DiskEncryptionProbe(resources: FakeResources(value: false))
        XCTAssertEqual(probe.isDataVolumeEncrypted(url), false)
    }

    func testUnknownValueStaysNil() {
        let probe = DiskEncryptionProbe(resources: FakeResources(value: nil))
        XCTAssertNil(probe.isDataVolumeEncrypted(url))
    }

    func testMissingPathReadsAsUnknown() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        XCTAssertNil(SystemVolumeResources().volumeIsEncrypted(at: missing))
    }

    func testDiskDescriptionFlagDecidesEncryption() {
        XCTAssertEqual(SystemVolumeResources.isEncrypted(diskDescription: ["DAMediaEncrypted": NSNumber(value: 1)]), true)
        XCTAssertEqual(SystemVolumeResources.isEncrypted(diskDescription: ["DAMediaEncrypted": NSNumber(value: 0)]), false)
    }

    func testDiskDescriptionWithoutFlagIsUnknown() {
        XCTAssertNil(SystemVolumeResources.isEncrypted(diskDescription: ["DAVolumeKind": "apfs"]))
    }

    func testHomeFolderIsReadFromItsRealVolume() {
        // Under a firmlink the volume URL says the sealed system volume, which is
        // never encrypted; the probe must answer for the volume holding the file.
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let probed = SystemVolumeResources().volumeIsEncrypted(at: home)
        let data = SystemVolumeResources().volumeIsEncrypted(at: URL(fileURLWithPath: "/System/Volumes/Data"))
        XCTAssertEqual(probed, data)
    }
}
