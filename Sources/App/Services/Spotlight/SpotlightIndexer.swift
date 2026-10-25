import Foundation

/// Publishes `SpotlightEntry`s to the on-device Spotlight index (and clears
/// them). Thin by design: all the "what/how" logic lives in the pure
/// `SpotlightItemBuilder`; this just maps entries to `CSSearchableItem`s and
/// talks to `CSSearchableIndex`.
///
/// The implementation is behind `#if canImport(CoreSpotlight)` with a no-op
/// fallback, so callers compile anywhere; on macOS the real path runs.
protocol SpotlightIndexing {
    func replaceIndex(with entries: [SpotlightEntry])
    func clear()
}

#if canImport(CoreSpotlight)
import CoreSpotlight
import UniformTypeIdentifiers

/// The two operations the indexer needs from `CSSearchableIndex`, so tests can
/// observe them without touching the real Spotlight index.
protocol SearchableIndex {
    func deleteItems(inDomain domain: String, completion: @escaping (Error?) -> Void)
    func index(_ items: [CSSearchableItem], completion: @escaping (Error?) -> Void)
}

struct SystemSearchableIndex: SearchableIndex {
    func deleteItems(inDomain domain: String, completion: @escaping (Error?) -> Void) {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain], completionHandler: completion)
    }

    func index(_ items: [CSSearchableItem], completion: @escaping (Error?) -> Void) {
        CSSearchableIndex.default().indexSearchableItems(items, completionHandler: completion)
    }
}

final class SpotlightIndexer: SpotlightIndexing {
    static let shared = SpotlightIndexer()

    private let index: SearchableIndex

    init(index: SearchableIndex = SystemSearchableIndex()) {
        self.index = index
    }

    /// Replaces everything we've indexed with the given entries. We delete our
    /// whole domain first so removed patients/sessions don't linger.
    func replaceIndex(with entries: [SpotlightEntry]) {
        index.deleteItems(inDomain: SpotlightItemBuilder.domainIdentifier) { [index] _ in
            guard !entries.isEmpty else { return }
            let items = entries.map { entry -> CSSearchableItem in
                let attributes = CSSearchableItemAttributeSet(contentType: .content)
                attributes.title = entry.title
                attributes.contentDescription = entry.contentDescription
                attributes.keywords = entry.keywords
                attributes.contentModificationDate = entry.contentModificationDate
                return CSSearchableItem(
                    uniqueIdentifier: entry.uniqueIdentifier,
                    domainIdentifier: SpotlightItemBuilder.domainIdentifier,
                    attributeSet: attributes
                )
            }
            index.index(items) { _ in }
        }
    }

    func clear() {
        index.deleteItems(inDomain: SpotlightItemBuilder.domainIdentifier) { _ in }
    }
}
#else
final class SpotlightIndexer: SpotlightIndexing {
    static let shared = SpotlightIndexer()
    func replaceIndex(with entries: [SpotlightEntry]) {}
    func clear() {}
}
#endif

/// Stands in for the real index while XCTest hosts the app, so a test run never
/// touches the developer's Spotlight index.
struct NoOpSpotlightIndexer: SpotlightIndexing {
    func replaceIndex(with entries: [SpotlightEntry]) {}
    func clear() {}
}

enum SpotlightIndexerFactory {
    /// The shared indexer, except under the test host.
    static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SpotlightIndexing {
        TestHost.isHostingTests(environment: environment) ? NoOpSpotlightIndexer() : SpotlightIndexer.shared
    }
}
