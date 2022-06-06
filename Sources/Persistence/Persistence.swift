import CoreData
import os

@available(iOS 14.0, *)
@available(macOS 11.0, *)
public class Persistence {
    private static let logger = Logger()
    
    public private(set) var text = "Hello, World!"
    
    public init(name: String, identifier: String, inMemory: Bool = false) {
        // TODO: NSPersistentContainer or NSPersistentCloudKitContainer
        container = NSPersistentCloudKitContainer(name: name)
        
        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        }
        
        let description = container.persistentStoreDescriptions.first
        description?.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description?.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        description?.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: identifier)
        
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

    public let container: NSPersistentCloudKitContainer
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
    public func save(completionHandler: @escaping (Result<Void, Error>) -> Void) -> Void {
        var err: Error?
        do {
            try self.container.viewContext.save()
        } catch {
            self.container.viewContext.rollback()
            Persistence.logger.error("While saving data, occured an unresolved error \(error.localizedDescription)")
            err = error
        }
        completionHandler(err != nil ? .failure(err!) : .success(()))
    }
}
