import XCTest

/// Quitting the real app, from the keyboard and from Terminal.
final class MenubarUITests: AcceptanceCase {
    func test_MENUBAR_16() {
        // Partial: the fixture app answers without loading weights, so this
        // covers the quit itself; MenubarSpec covers the model's unload.
        given.theAppOpenWithASession()

        let quit = when.pressCommandQ()

        then(quit).closedWithoutACrashReport()
    }

    func test_MENUBAR_17() {
        given.theAppOpenWithASession()

        let quit = when.sendTheQuitSignalFromTerminal()

        then(quit).closedWithoutACrashReport()
    }
}
