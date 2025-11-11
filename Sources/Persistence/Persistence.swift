import CoreData
import os

@available(iOS 17.0, *)
@available(macOS 14.0, *)
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
        let currentContextName = container.viewContext.name
        container.viewContext.name = contextName
        save { result in
            self.container.viewContext.name = currentContextName
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
                container.viewContext.rollback()
                Persistence.logger.error("While saving data, occured an unresolved error \(error.localizedDescription, privacy: .public): \(Thread.callStackSymbols, privacy: .public)")
                
                completionHandler(.failure(error))
            }
        }
    }
    
    public func save() async throws {
        guard container.viewContext.hasChanges else {
            Persistence.logger.debug("There are no changes to save")
            return
        }
        try container.viewContext.save()
    }
    
    public func perform(_ block: @escaping @Sendable () -> Void) -> Void {
        container.viewContext.perform(block)
    }
    
    // MARK: - Helper
    nonisolated public func count(_ entityName: String) -> Int {
        var count = 0
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
        do {
            count = try self.container.viewContext.count(for: fetchRequest)
        } catch {
            Persistence.logger.error("Can't count \(entityName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return count
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
