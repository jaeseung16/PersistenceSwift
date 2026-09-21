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

    private static func makeModel() -> NSManagedObjectModel {
        let text = NSAttributeDescription()
        text.name = "text"
        text.attributeType = .stringAttributeType
        text.isOptional = true
        let note = NSEntityDescription()
        note.name = "Note"
        note.properties = [text]
        let model = NSManagedObjectModel()
        model.entities = [note]
        return model
    }

    private func insertNote(into persistence: Persistence, author: String) async throws {
        let context = persistence.container.viewContext
        await context.perform {
            context.transactionAuthor = author
            let note = NSManagedObject(entity: context.persistentStoreCoordinator!.managedObjectModel.entitiesByName["Note"]!, insertInto: context)
            note.setValue(author, forKey: "text")
        }
        try await persistence.save()
    }

    func testFetchUpdatesSkipsExcludedAuthors() async throws {
        let model = Self.makeModel()
        let persistence = Persistence(name: "persistence-authors",
                                      identifier: "iCloud.com.resonance.jlee.persistence",
                                      model: model,
                                      inMemory: true,
                                      isCloud: false)
        await persistence.invalidateHistoryToken()

        try await insertNote(into: persistence, author: "App")
        let ownChanges = try await persistence.fetchUpdates(excludingAuthors: ["App"])
        XCTAssertTrue(ownChanges.isEmpty)

        try await insertNote(into: persistence, author: "Other")
        let otherChanges = try await persistence.fetchUpdates(excludingAuthors: ["App"])
        XCTAssertEqual(otherChanges.count, 1)

        // The excluded transaction was consumed, not left for the next fetch
        let noChanges = try await persistence.fetchUpdates()
        XCTAssertTrue(noChanges.isEmpty)
    }
}
