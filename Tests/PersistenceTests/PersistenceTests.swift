import XCTest
@testable import Persistence

final class PersistenceTests: XCTestCase {
    // In-memory, non-cloud container so the test does not need CloudKit
    // entitlements or touch a real store file.
    private func makePersistence() -> Persistence {
        Persistence(name: "persistence",
                    identifier: "iCloud.com.resonance.jlee.persistence",
                    model: NSManagedObjectModel(),
                    inMemory: true,
                    isCloud: false)
    }

    func testLocalContainerHasNoCloudContainer() async throws {
        let persistence = makePersistence()
        let cloudContainer = await persistence.cloudContainer
        XCTAssertNil(cloudContainer)
    }

    func testSaveWithoutChangesDoesNotThrow() async throws {
        let persistence = makePersistence()
        try await persistence.save()
        try await persistence.save(with: "test-context")
    }

    // Drives the history-request path, which runs HistoryRequestHandler's
    // jobs on its background context's queue via the custom executor.
    func testFetchUpdatesOnEmptyStoreReturnsNothing() async throws {
        let persistence = makePersistence()
        // Discard any token left on disk by a previous run so the fetch
        // starts from the beginning of (empty) history.
        await persistence.invalidateHistoryToken()
        let objectIDs = try await persistence.fetchUpdates()
        XCTAssertTrue(objectIDs.isEmpty)
    }
}
