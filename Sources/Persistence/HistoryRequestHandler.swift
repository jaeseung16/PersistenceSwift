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
    private let backgroundContext: NSManagedObjectContext
    private let executor: ManagedObjectContextExecutor
    private var activeFetch: Task<[NSManagedObjectID], Error>?

    // The actor's jobs run on backgroundContext's queue, so history requests
    // can use the context directly instead of blocking in performAndWait.
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    init(container: NSPersistentContainer, historyToken: HistoryToken) {
        self.container = container
        self.historyToken = historyToken
        let backgroundContext = container.newBackgroundContext()
        self.backgroundContext = backgroundContext
        self.executor = ManagedObjectContextExecutor(context: backgroundContext)
    }

    // MARK: - Purge History
    private var needsPurge = true

    // History already consumed before the stored token only wastes disk
    // space, so purging can wait until the first fetch pass instead of
    // racing an unstructured task at init.
    private func purgeHistoryIfNeeded() {
        guard needsPurge else {
            return
        }
        needsPurge = false
        purgeHistory()
    }

    private func purgeHistory() {
        guard let token = historyToken.getToken() else {
            return
        }
        
        let purgeHistoryRequest = NSPersistentHistoryChangeRequest.deleteHistory(before: token)
        do {
            _ = try backgroundContext.execute(purgeHistoryRequest)
        } catch {
            logger.error("Could not purge history: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    public func invalidateHistoryToken() async {
        historyToken.setToken(nil)
    }
    
    // MARK: - Persistence History Request
    public func fetchUpdates() async throws -> [NSManagedObjectID] {
        // The actor is reentrant at the awaits inside processUpdates(): a
        // second call arriving mid-pass would re-read the same history token
        // and merge the same transactions twice. Concurrent callers therefore
        // join the in-flight pass instead of starting their own.
        if let activeFetch {
            return try await activeFetch.value
        }
        let fetch = Task {
            defer { activeFetch = nil }
            return try await processUpdates()
        }
        activeFetch = fetch
        return try await fetch.value
    }

    private func processUpdates() async throws -> [NSManagedObjectID] {
        purgeHistoryIfNeeded()

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

        guard let historyResult = try backgroundContext.execute(fetchHistoryRequest) as? NSPersistentHistoryResult else {
            throw PersistenceError.fetchHistoryFailed
        }

        guard let historyTransactions = historyResult.result as? [NSPersistentHistoryTransaction] else {
            throw PersistenceError.historyTransactionsNotFound
        }
        
        return historyTransactions.reversed()
    }
    
}
