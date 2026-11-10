import XCTest

/// XCTAssertThrowsError for an async expression.
func assertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T,
                          file: StaticString = #filePath, line: UInt = #line,
                          _ handler: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
