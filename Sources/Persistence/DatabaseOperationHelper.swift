//
//  File.swift
//  
//
//  Created by Jae Seung Lee on 6/12/22.
//

import Foundation
import CoreData
import CloudKit
import os

public class DatabaseOperationHelper {
    private let logger = Logger()
    
    private let notificationTokenHelper: NotificationTokenHelper
    private var tokenCache = [NotificationTokenType: CKServerChangeToken]()
    
    public init(appName: String) {
        self.notificationTokenHelper = NotificationTokenHelper(appName: appName)
    }
    
    private var serverToken: CKServerChangeToken? {
        let serverToken = try? notificationTokenHelper.read(.server)
        if serverToken != nil {
            tokenCache[.zone] = serverToken
        }
        return serverToken
    }
    
    public func addDatabaseChangesOperation(database: CKDatabase, completionHandler: @escaping (Result<CKRecord, Error>) -> Void) -> Void {
        let dbChangesOperation = CKFetchDatabaseChangesOperation(previousServerChangeToken: self.serverToken)
        
        dbChangesOperation.recordZoneWithIDChangedBlock = {
            self.addZoneChangesOperation(database: database, zoneId: $0, completionHandelr: completionHandler)
        }
        
        dbChangesOperation.changeTokenUpdatedBlock = { token in
            self.tokenCache[.server] = token
        }

        dbChangesOperation.fetchDatabaseChangesResultBlock = { result in
            switch result {
            case .success((let token, _)):
                try? self.notificationTokenHelper.write(token, for: .server)
            case .failure(let error):
                self.logger.log("Failed to fetch database changes: \(String(describing: error))")
                if let lastToken = self.tokenCache[.server] {
                    try? self.notificationTokenHelper.write(lastToken, for: .server)
                }
            }
        }
        
        dbChangesOperation.qualityOfService = .utility
        database.add(dbChangesOperation)
    }
    
    private var zoneToken: CKServerChangeToken? {
        let zoneToken = try? notificationTokenHelper.read(.zone)
        if zoneToken != nil {
            tokenCache[.zone] = zoneToken
        }
        return zoneToken
    }
    
    private func addZoneChangesOperation(database: CKDatabase, zoneId: CKRecordZone.ID, completionHandelr: @escaping (Result<CKRecord, Error>) -> Void) -> Void {
        var configurations = [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]()
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = self.zoneToken
        configurations[zoneId] = config
        
        let zoneChangesOperation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneId], configurationsByRecordZoneID: configurations)
        
        zoneChangesOperation.recordWasChangedBlock = { recordID, result in
            switch(result) {
            case .success(let record):
                completionHandelr(.success(record))
            case .failure(let error):
                self.logger.log("Failed to check if record was changed: recordID=\(recordID, privacy: .public), error=\(error.localizedDescription, privacy: .public))")
                completionHandelr(.failure(error))
            }
        }
        
        zoneChangesOperation.recordZoneChangeTokensUpdatedBlock = { recordZoneID, token, _ in
            self.tokenCache[.zone] = token
        }
        
        zoneChangesOperation.recordZoneFetchResultBlock = { recordZoneID, result in
            switch(result) {
            case .success((let serverToken, _, _)):
                try? self.notificationTokenHelper.write(serverToken, for: .zone)
            case .failure(let error):
                self.logger.log("Failed to fetch zone changes: recordZoneID=\(recordZoneID, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
                if let lastToken = self.tokenCache[.zone] {
                    try? self.notificationTokenHelper.write(lastToken, for: .zone)
                }
            }
        }
        
        zoneChangesOperation.qualityOfService = .utility
        database.add(zoneChangesOperation)
    }
}

