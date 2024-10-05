import CoreData
import os

@available(iOS 14.0, *)
@available(macOS 11.0, *)
public class Persistence {
    private static let logger = Logger()
    
    public private(set) var container: NSPersistentContainer
    public private(set) var usingCloud: Bool
    
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
        
        historyToken = HistoryToken(appPathComponent: name)
        
        purgeHistory()
    }
    
    public var historyToken: HistoryToken

    // MARK: - Purge History
    private func purgeHistory() {
        let purgeHistoryRequest = NSPersistentHistoryChangeRequest.deleteHistory(before: historyToken.last)
        do {
            try container.newBackgroundContext().execute(purgeHistoryRequest)
        } catch {
            if let error = error as NSError? {
                Persistence.logger.error("Could not purge history: \(error), \(error.userInfo)")
            }
        }
    }
    
    public func invalidateHistoryToken() {
        historyToken.last = nil
    }
    
    // MARK: - Persistence History Request
    private lazy var historyRequestQueue = DispatchQueue(label: "history")
    public func fetchUpdates(_ notification: Notification, completionHandler: @escaping (Result<Void, Error>) -> Void) -> Void {
        historyRequestQueue.async {
            let backgroundContext = self.container.newBackgroundContext()
            backgroundContext.performAndWait {
                do {
                    let fetchHistoryRequest = NSPersistentHistoryChangeRequest.fetchHistory(after: self.historyToken.last)
                    
                    if let historyResult = try backgroundContext.execute(fetchHistoryRequest) as? NSPersistentHistoryResult,
                       let history = historyResult.result as? [NSPersistentHistoryTransaction] {
                        for transaction in history.reversed() {
                            self.container.viewContext.perform {
                                self.container.viewContext.mergeChanges(fromContextDidSave: transaction.objectIDNotification())
                                self.historyToken.last = transaction.token
                            }
                        }

                        completionHandler(.success(()))
                    }
                } catch {
                    Persistence.logger.error("Could not convert history result to transactions after lastToken = \(String(describing: self.historyToken.last)): \(error.localizedDescription)")
                    completionHandler(.failure(error))
                }
            }
        }
    }
    
    // MARK: - Save
    public func save(with contextName: String, completionHandler: @escaping (Result<Void, Error>) -> Void) -> Void {
        var currentContextName = container.viewContext.name
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
                self.container.viewContext.rollback()
                Persistence.logger.error("While saving data, occured an unresolved error \(error.localizedDescription, privacy: .public): \(Thread.callStackSymbols, privacy: .public)")
                
                completionHandler(.failure(error))
            }
        }
    }
    
    public func save() async throws {
        guard self.container.viewContext.hasChanges else {
            Persistence.logger.debug("There are no changes to save")
            return
        }
        try self.container.viewContext.save()
    }
    
    // MARK: - Helper
    public func count(_ entityName: String) -> Int {
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
    public func createCoreSpotlightDelegate<T: NSCoreDataCoreSpotlightDelegate>() -> T? {
        if let persistentStoreDescription = container.persistentStoreDescriptions.first {
            return T(forStoreWith: persistentStoreDescription, coordinator: container.persistentStoreCoordinator)
        }
        Persistence.logger.log("Can't initialize NSCoreDataCoreSpotlightDelegate: container.persistentStoreDescriptions=\(self.container.persistentStoreDescriptions, privacy: .public)")
        return nil
    }
}
