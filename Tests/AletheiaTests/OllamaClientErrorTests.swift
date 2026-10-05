import XCTest
@testable import Aletheia

final class OllamaClientErrorTests: XCTestCase {
    func testConnectionLevelURLErrorsAreTreatedAsNotReachable() {
        for code: URLError.Code in [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                                    .notConnectedToInternet, .timedOut, .dnsLookupFailed, .resourceUnavailable] {
            XCTAssertTrue(OllamaClient.isConnectionFailure(URLError(code)),
                          "\(code) should map to 'not reachable'")
        }
    }

    func testNonConnectionErrorsAreNotConnectionFailures() {
        XCTAssertFalse(OllamaClient.isConnectionFailure(URLError(.badServerResponse)))
        XCTAssertFalse(OllamaClient.isConnectionFailure(OllamaError.badResponse))
        XCTAssertFalse(OllamaClient.isConnectionFailure(OllamaError.modelNotFound("llama3.1:8b")))
    }

    func testNotReachableMessageNamesOllama() {
        XCTAssertTrue((OllamaError.notReachable.errorDescription ?? "").contains("Ollama"))
    }
}
