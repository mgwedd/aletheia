import ObjectiveC
import XCTest

/// Keeps the three layers tied together: ACCEPTANCE-CRITERIA.md, the `qa:` tags
/// in BEHAVIOR-REFERENCE.md and the fitness functions that exist at runtime.
/// Fitness functions assert the intended behavior, so a red one is an honest
/// result; this test only checks that every check has one.
final class SpecCoverageTests: XCTestCase {
    func test_everyCheckHasATestAndEveryLayerAgrees() {
        let criteria = SpecDocs.loadCriteria()
        XCTAssertFalse(criteria.checks.isEmpty, "no checks found in docs/spec/ACCEPTANCE-CRITERIA.md")
        let reference = SpecDocs.loadReference(knownChecks: criteria.ids)
        XCTAssertFalse(reference.itemIDs.isEmpty, "no items found in docs/spec/BEHAVIOR-REFERENCE.md")

        let found = Self.discoverTests()
        let problems = SpecDocs.coverageProblems(criteria: criteria, reference: reference, tests: found.counts)
            + found.problems
        report(problems)
    }

    func test_noUnusedCopyNoExpectedFailuresNoFixedDelays() {
        let sources = SpecDocs.suiteSources()
        XCTAssertFalse(sources.isEmpty, "acceptance sources not found next to the docs")
        report(SpecDocs.unusedCopyEntries(files: sources) + SpecDocs.expectFailureProblems(files: sources)
               + SpecDocs.fixedDelayProblems(files: sources))
    }

    private func report(_ problems: [String]) {
        if !problems.isEmpty {
            XCTFail("\(problems.count) spec problem(s):\n" + problems.map { "  - \($0)" }.joined(separator: "\n"))
        }
    }

    // MARK: Runtime enumeration

    /// How many `test_<JOURNEY>_<NN>` methods each check has, read from the
    /// Objective-C runtime: every subclass of `AcceptanceCase`, its own methods.
    static func discoverTests() -> (counts: [String: Int], problems: [String]) {
        var counts: [String: Int] = [:]
        var problems: [String] = []
        for cls in subclasses(of: AcceptanceCase.self) {
            var methodCount: UInt32 = 0
            guard let methods = class_copyMethodList(cls, &methodCount) else { continue }
            defer { free(methods) }
            for index in 0..<Int(methodCount) {
                let selector = NSStringFromSelector(method_getName(methods[index]))
                guard selector.hasPrefix("test") else { continue }
                // Async tests are exposed as `test_X_01WithCompletionHandler:`.
                guard let groups = selector.captures(#"^test_([A-Z]+)_(\d{2})(?:WithCompletionHandler:)?$"#) else {
                    problems.append("\(cls).\(selector) does not name a check (want test_<JOURNEY>_<NN>)")
                    continue
                }
                counts["\(groups[0])-\(groups[1])", default: 0] += 1
            }
        }
        return (counts, problems)
    }

    /// Subclasses of `base`, found by walking every registered class as a raw
    /// pointer. Some runtime classes cannot be retained, so a strong `AnyClass`
    /// must not be formed for a class until it is known to descend from `base`.
    private static func subclasses(of base: AnyClass) -> [AnyClass] {
        let target = unsafeBitCast(base, to: UnsafeRawPointer.self)
        let total = Int(objc_getClassList(nil, 0))
        let buffer = UnsafeMutablePointer<AnyClass>.allocate(capacity: total)
        defer { buffer.deallocate() }
        let filled = Int(objc_getClassList(AutoreleasingUnsafeMutablePointer(buffer), Int32(total)))
        var found: [AnyClass] = []
        for index in 0..<min(filled, total) {
            let cls = UnsafeRawPointer(buffer).load(fromByteOffset: index * MemoryLayout<UnsafeRawPointer>.size, as: UnsafeRawPointer.self)
            var parent = rawSuperclass(cls)
            while let current = parent {
                if current == target {
                    found.append(unsafeBitCast(cls, to: AnyClass.self))
                    break
                }
                parent = rawSuperclass(current)
            }
        }
        return found
    }
}

/// `class_getSuperclass` taking and returning raw pointers, so no reference is
/// formed (and none retained) while scanning unrelated classes.
@_silgen_name("class_getSuperclass")
private func rawSuperclass(_ cls: UnsafeRawPointer) -> UnsafeRawPointer?
