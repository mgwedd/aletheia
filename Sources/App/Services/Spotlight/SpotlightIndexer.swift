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

final class SpotlightIndexer: SpotlightIndexing {
    static let shared = SpotlightIndexer()

    private let index = CSSearchableIndex.default()

    /// Replaces everything we've indexed with the given entries. We delete our
    /// whole domain first so removed patients/sessions don't linger.
    func replaceIndex(with entries: [SpotlightEntry]) {
        index.deleteSearchableItems(withDomainIdentifiers: [SpotlightItemBuilder.domainIdentifier]) { [index] _ in
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
            index.indexSearchableItems(items) { _ in }
        }
    }

    func clear() {
        index.deleteSearchableItems(withDomainIdentifiers: [SpotlightItemBuilder.domainIdentifier]) { _ in }
    }
}
#else
final class SpotlightIndexer: SpotlightIndexing {
    static let shared = SpotlightIndexer()
    func replaceIndex(with entries: [SpotlightEntry]) {}
    func clear() {}
}
#endif
