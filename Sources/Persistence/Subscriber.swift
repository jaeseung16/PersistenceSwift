//
//  File.swift
//  
//
//  Created by Jae Seung Lee on 6/12/22.
//

import Foundation
import CloudKit
import CoreData
import os

public class Subscriber {
    private static let logger = Logger()
    
    let database: CKDatabase
    let subscriptionID: String
    let recordType: String
    
    init(database: CKDatabase, subscriptionID: String, recordType: String) {
        self.database = database
        self.subscriptionID = subscriptionID
        self.recordType = recordType
    }
    
    public func subscribe(completionHandler: @escaping (Result<CKSubscription, Error>) -> Void) -> Void {
        let fetchSubscriptionsOperation = CKFetchSubscriptionsOperation(subscriptionIDs: [subscriptionID])
        fetchSubscriptionsOperation.fetchSubscriptionsResultBlock = { result in
            switch result {
            case .success():
                Subscriber.logger.log("subscribe success to fetch subscriptions")
            case .failure(let error):
                Subscriber.logger.log("subscribe failed to find subscriptions: \(error.localizedDescription, privacy: .public))")
            }
        }
        
        fetchSubscriptionsOperation.perSubscriptionResultBlock = { (subscriptionID, result) in
            if subscriptionID == self.subscriptionID {
                switch result {
                case .success(let subscription):
                    Subscriber.logger.log("subscribe found: \(String(describing: subscription))")
                    completionHandler(.success((subscription)))
                case .failure(let error):
                    Subscriber.logger.log("subscribe can't find: \(String(describing: error))")
                    self.addSubscription(completionHandler: completionHandler)
                }
            }
        }
        
        database.add(fetchSubscriptionsOperation)
    }
    
    private func addSubscription(completionHandler: @escaping (Result<CKSubscription, Error>) -> Void) -> Void {
        let subscription = CKDatabaseSubscription(subscriptionID: subscriptionID)
        subscription.recordType = recordType
        subscription.notificationInfo = CKSubscription.NotificationInfo()
                
        let operation = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: nil)
        operation.qualityOfService = .utility
        operation.modifySubscriptionsResultBlock = { result in
            switch result {
            case .success():
                completionHandler(.success((subscription)))
            case .failure(let error):
                Subscriber.logger.log("Failed to modify subscription: \(error.localizedDescription, privacy: .public)")
                completionHandler(.failure((error)))
            }
        }
        database.add(operation)
    }
}
