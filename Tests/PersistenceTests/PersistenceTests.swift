import XCTest
@testable import Persistence

final class PersistenceTests: XCTestCase {
    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        XCTAssertEqual(Persistence(name: "persistence", identifier: "iCloud.com.resonance.jlee.persistence").text, "Hello, World!")
    }
}
