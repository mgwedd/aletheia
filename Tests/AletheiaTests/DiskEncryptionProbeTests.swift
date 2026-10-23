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
}
