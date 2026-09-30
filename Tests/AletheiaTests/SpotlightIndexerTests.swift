import XCTest
@testable import Aletheia

final class SpotlightIndexerTests: XCTestCase {
    func testSpotlightIndexerSharedInstanceMethodsDoNotCrash() {
        let indexer = SpotlightIndexer.shared
        let entry = SpotlightEntry(
            uniqueIdentifier: "test-id",
            title: "Test Title",
            contentDescription: "Test Description",
            keywords: ["keyword1"],
            contentModificationDate: Date()
        )

        indexer.replaceIndex(with: [entry])
        indexer.clear()
    }
}
