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
        self.logger.log("Adding a database change operation for database=\(database, privacy: .public)")
        
        let dbChangesOperation = CKFetchDatabaseChangesOperation(previousServerChangeToken: self.serverToken)
        
        dbChangesOperation.recordZoneWithIDChangedBlock = {
            self.addZoneChangesOperation(database: database, zoneId: $0, completionHandler: completionHandler)
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
        var zoneToken: CKServerChangeToken?
        do {
            zoneToken = try notificationTokenHelper.read(.zone)
        } catch {
            self.logger.log("Failed to read zone token: \(String(describing: error))")
        }
        
        if zoneToken != nil {
            tokenCache[.zone] = zoneToken
        }
        return zoneToken
    }
    
    private func addZoneChangesOperation(database: CKDatabase, zoneId: CKRecordZone.ID, completionHandler: @escaping (Result<CKRecord, Error>) -> Void) -> Void {
        var configurations = [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]()
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = self.zoneToken
        configurations[zoneId] = config
        
        let zoneChangesOperation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneId], configurationsByRecordZoneID: configurations)
        
        zoneChangesOperation.recordWasChangedBlock = { recordID, result in
            switch(result) {
            case .success(let record):
                completionHandler(.success(record))
            case .failure(let error):
                self.logger.log("Failed to check if record was changed: recordID=\(recordID, privacy: .public), error=\(error.localizedDescription, privacy: .public))")
                completionHandler(.failure(error))
            }
        }
        
        zoneChangesOperation.recordZoneChangeTokensUpdatedBlock = { recordZoneID, token, _ in
            self.tokenCache[.zone] = token
        }
        
        zoneChangesOperation.recordZoneFetchResultBlock = { recordZoneID, result in
            switch(result) {
            case .success((let serverToken, _, _)):
                do {
                    try self.notificationTokenHelper.write(serverToken, for: .zone)
                } catch {
                    self.logger.log("Failed to write notification token: serverToken=\(serverToken, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
                }
            case .failure(let error):
                self.logger.log("Failed to fetch zone changes: recordZoneID=\(recordZoneID, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
                if let lastToken = self.tokenCache[.zone] {
                    do {
                        try self.notificationTokenHelper.write(lastToken, for: .zone)
                    } catch {
                        self.logger.log("Failed to write notification token: lastToken=\(lastToken, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
        
        zoneChangesOperation.qualityOfService = .utility
        database.add(zoneChangesOperation)
    }
}

