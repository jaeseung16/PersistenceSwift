import CoreData
import os

@available(iOS 26.0, *)
@available(macOS 26.0, *)
public actor Persistence {
    private static let logger = Logger()
    
    nonisolated public let container: NSPersistentContainer
    private let usingCloud: Bool
    private let historyRequestHandler: HistoryRequestHandler
    
    public var cloudContainer: NSPersistentCloudKitContainer? {
        return usingCloud ? container as? NSPersistentCloudKitContainer : nil
    }
    
    public init(name: String, identifier: String, inMemory: Bool = false, isCloud: Bool = true) {
        self.usingCloud = isCloud
        container = isCloud ? NSPersistentCloudKitContainer(name: name) : NSPersistentContainer(name: name)
        
        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        }
        
        let description = container.persistentStoreDescriptions.first
        description?.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description?.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        if isCloud {
            description?.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: identifier)
        }
        
        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                Persistence.logger.error("Could not load persistent store: \(storeDescription), \(error), \(error.userInfo)")
            }
        })
        
        Persistence.logger.log("persistentStores = \(String(describing: self.container.persistentStoreCoordinator.persistentStores))")
        container.viewContext.name = name
        
        historyRequestHandler = HistoryRequestHandler(container: container, historyToken: HistoryToken(appPathComponent: name))
        
        Task {
            await historyRequestHandler.purgeHistory()
        }
    }
    
    public func invalidateHistoryToken() async {
        await historyRequestHandler.invalidateHistoryToken()
    }
    
    public func fetchUpdates() async throws -> [NSManagedObjectID] {
        return try await historyRequestHandler.fetchUpdates()
    }
    
    // MARK: - Save
    public func save(with contextName: String, completionHandler: @escaping (Result<Void, Error>) -> Void) -> Void {
        let context = container.viewContext
        let currentContextName = context.performAndWait { context.name }
        context.performAndWait {
            context.name = contextName
        }
        save { result in
            context.perform {
                context.name = currentContextName
            }
            completionHandler(result)
        }
    }

    @available(*, renamed: "save()")
    public func save(completionHandler: @escaping (Result<Void, Error>) -> Void) -> Void {
        Task {
            do {
                try await save()
                completionHandler(.success(()))
            } catch {
                let context = container.viewContext
                await context.perform {
                    context.rollback()
                }
                Persistence.logger.error("While saving data, occured an unresolved error \(error.localizedDescription, privacy: .public): \(Thread.callStackSymbols, privacy: .public)")
                
                completionHandler(.failure(error))
            }
        }
    }
    
    public func save() async throws {
        // viewContext is main-queue confined; the actor executor is not the main queue,
        // so every touch of the context must go through perform.
        let context = container.viewContext
        try await context.perform {
            guard context.hasChanges else {
                Persistence.logger.debug("There are no changes to save")
                return
            }
            try context.save()
        }
    }
    
    public func perform(_ block: @escaping @Sendable () -> Void) -> Void {
        container.viewContext.perform(block)
    }
    
    // MARK: - Helper
    nonisolated public func count(_ entityName: String) -> Int {
        let context = container.viewContext
        return context.performAndWait {
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
            do {
                return try context.count(for: fetchRequest)
            } catch {
                Persistence.logger.error("Can't count \(entityName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return 0
            }
        }
    }
    
    // MARK: - NSCoreDataCoreSpotlightDelegate
    nonisolated public func createCoreSpotlightDelegate<T: NSCoreDataCoreSpotlightDelegate>() -> T? {
        if let persistentStoreDescription = container.persistentStoreDescriptions.first {
            return T(forStoreWith: persistentStoreDescription, coordinator: container.persistentStoreCoordinator)
        }
        Persistence.logger.log("Can't initialize NSCoreDataCoreSpotlightDelegate: container.persistentStoreDescriptions=\(self.container.persistentStoreDescriptions, privacy: .public)")
        return nil
    }
}
