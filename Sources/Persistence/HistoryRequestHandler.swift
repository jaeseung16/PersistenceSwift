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
    private static let logger = Logger()
    
    private let container: NSPersistentContainer
    private let historyToken: HistoryToken

    init(container: NSPersistentContainer, historyToken: HistoryToken) {
        self.container = container
        self.historyToken = historyToken
    }
    
    // MARK: - Purge History
    func purgeHistory() {
        Task {
            guard let token = await historyToken.getToken() else {
                return
            }
            
            let purgeHistoryRequest = NSPersistentHistoryChangeRequest.deleteHistory(before: token)
            do {
                try container.newBackgroundContext().execute(purgeHistoryRequest)
            } catch {
                if let error = error as NSError? {
                    HistoryRequestHandler.logger.error("Could not purge history: \(error), \(error.userInfo)")
                }
            }
        }
        
    }
    
    public func invalidateHistoryToken() async {
        await historyToken.setToken(nil)
    }
    
    // MARK: - Persistence History Request
    
    public func fetchUpdates(_ notification: Notification, completionHandler: @escaping @Sendable (Result<Notification, Error>) -> Void) -> Void {
        Task {
            do {
                let history = try await fetchHistoryTransactions(notification)
                for transaction in history.reversed() {
                    completionHandler(.success(transaction.objectIDNotification()))
                    Task {
                        await self.historyToken.setToken(transaction.token)
                    }
                }
            } catch {
                completionHandler(.failure(error))
            }
            
        }
    }
    
    private func fetchHistoryTransactions(_ notification: Notification) async throws -> [NSPersistentHistoryTransaction] {
        guard let token = await historyToken.getToken() else {
            HistoryRequestHandler.logger.error("Could not find token")
            throw PersistenceError.tokenNotFound
        }
        
        let fetchHistoryRequest = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
        let backgroundContext = self.container.newBackgroundContext()
        
        guard let historyResult = try backgroundContext.execute(fetchHistoryRequest) as? NSPersistentHistoryResult else {
            HistoryRequestHandler.logger.error("Could not execute fetch history request")
            throw PersistenceError.fetchHistoryFailed
        }

        guard let historyTransactions = historyResult.result as? [NSPersistentHistoryTransaction] else {
            HistoryRequestHandler.logger.error("Could not cast history transactions")
            throw PersistenceError.historyTransactionsNotFound
        }
        
        return historyTransactions.reversed()
    }
    
}
