//
//  File.swift
//  Persistence
//
//  Created by Jae Seung Lee on 10/26/24.
//

import Foundation
@preconcurrency import CoreData
import os

actor HistoryRequestHandler {
    private let logger = Logger()
    
    private let container: NSPersistentContainer
    private let historyToken: HistoryToken

    init(container: NSPersistentContainer, historyToken: HistoryToken) {
        self.container = container
        self.historyToken = historyToken
    }
    
    // MARK: - Purge History
    func purgeHistory() {
        guard let token = historyToken.getToken() else {
            return
        }
        
        let purgeHistoryRequest = NSPersistentHistoryChangeRequest.deleteHistory(before: token)
        let backgroundContext = container.newBackgroundContext()
        do {
            // Background contexts are private-queue confined; execute must run on that queue.
            try backgroundContext.performAndWait {
                _ = try backgroundContext.execute(purgeHistoryRequest)
            }
        } catch {
            logger.error("Could not purge history: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    public func invalidateHistoryToken() async {
        historyToken.setToken(nil)
    }
    
    // MARK: - Persistence History Request
    public func fetchUpdates(_ notification: Notification, completionHandler: @escaping @Sendable (Result<Notification, Error>) -> Void) -> Void {
        do {
            let transactions = try fetchHistoryTransactions()
            for transaction in transactions {
                completionHandler(.success(transaction.objectIDNotification()))
                self.historyToken.setToken(transaction.token)
            }
        } catch {
            completionHandler(.failure(error))
        }
    }
    
    public func fetchUpdates() async throws -> [NSManagedObjectID] {
        let transactions = try fetchHistoryTransactions()
        
        var results: [NSManagedObjectID] = []
        for transaction in transactions {
            // Safe to send into the perform block: created locally and only read again after the await completes.
            nonisolated(unsafe) let notification = transaction.objectIDNotification()
            
            // viewContext is main-queue confined; merging from the actor executor races against main-thread use of the context.
            let context = container.viewContext
            await context.perform {
                context.mergeChanges(fromContextDidSave: notification)
            }

            if let userInfo = notification.userInfo {
                userInfo.forEach { key, value in
                    if let objectIDs = value as? Set<NSManagedObjectID> {
                        results.append(contentsOf: objectIDs)
                    }
                }
            }
            historyToken.setToken(transaction.token)
        }
        return results
    }
    
    private func fetchHistoryTransactions() throws -> [NSPersistentHistoryTransaction] {
        let token = historyToken.getToken()
        
        let fetchHistoryRequest = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
        let backgroundContext = container.newBackgroundContext()

        // Background contexts are private-queue confined; execute must run on that queue.
        guard let historyResult = try backgroundContext.performAndWait({
            try backgroundContext.execute(fetchHistoryRequest) as? NSPersistentHistoryResult
        }) else {
            throw PersistenceError.fetchHistoryFailed
        }

        guard let historyTransactions = historyResult.result as? [NSPersistentHistoryTransaction] else {
            throw PersistenceError.historyTransactionsNotFound
        }
        
        return historyTransactions.reversed()
    }
    
}
