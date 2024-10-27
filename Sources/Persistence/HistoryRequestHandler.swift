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
    
    public func fetchUpdates(_ notification: Notification, completionHandler: @escaping @Sendable (Result<Void, Error>) -> Void) -> Void {
        Task {
            guard let token = await self.historyToken.getToken() else {
                completionHandler(.failure(PersistenceError.tokenNotFound))
                return
            }
            
            let fetchHistoryRequest = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
            let backgroundContext = self.container.newBackgroundContext()
            
            if let historyResult = try backgroundContext.execute(fetchHistoryRequest) as? NSPersistentHistoryResult,
               let history = historyResult.result as? [NSPersistentHistoryTransaction] {
                for transaction in history.reversed() {
                    self.container.viewContext.mergeChanges(fromContextDidSave: transaction.objectIDNotification())
                    
                    Task {
                        await self.historyToken.setToken(transaction.token)
                    }
                }
                completionHandler(.success(()))
            }
        }
    }
    
}
