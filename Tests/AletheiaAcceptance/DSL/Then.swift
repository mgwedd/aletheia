import XCTest

/// An expectation about `subject`. Journeys add expectations for their own
/// subjects with `extension Then where Subject == X`, and report through
/// `fail`, which puts the check's QA line in front of the message.
struct Then<Subject> {
    let subject: Subject
    let check: Check
    let file: StaticString
    let line: UInt

    func fail(_ message: String) {
        XCTFail("\(check.headline)\n\(message)", file: file, line: line)
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { fail(message()) }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ what: String) {
        if actual != expected { fail("expected \(what) to be \(expected), found \(actual)") }
    }
}
