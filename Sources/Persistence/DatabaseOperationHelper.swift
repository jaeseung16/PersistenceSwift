//
//  File.swift
//
//
//  Created by Jae Seung Lee on 6/12/22.
//

import Foundation
import CoreData
import CloudKit
import Synchronization
import os

// CKServerChangeToken is an immutable, thread-safe value but is not annotated
// Sendable in the SDK; the box lets tokens live inside Mutex-protected state.
private struct TokenBox: @unchecked Sendable {
    let token: CKServerChangeToken

    init(_ token: CKServerChangeToken) {
        self.token = token
    }
}

public final class DatabaseOperationHelper: Sendable {
    private let logger = Logger()

    private let notificationTokenHelper: NotificationTokenHelper
    // Guards the in-memory cache and the token files as one unit: CloudKit
    // invokes the operation callbacks on its own queues, so any token access
    // below may run concurrently with the others.
    private let tokenCache = Mutex<[NotificationTokenType: TokenBox]>([:])

    public init(appName: String) {
        self.notificationTokenHelper = NotificationTokenHelper(appName: appName)
    }

    private func lastToken(for tokenType: NotificationTokenType) -> CKServerChangeToken? {
        let box: TokenBox? = tokenCache.withLock { cache in
            do {
                guard let token = try notificationTokenHelper.read(tokenType) else {
                    return nil
                }
                let box = TokenBox(token)
                cache[tokenType] = box
                return box
            } catch {
                logger.log("Failed to read \(tokenType.rawValue, privacy: .public) token: \(String(describing: error))")
                return nil
            }
        }
        return box?.token
    }

    private func cache(_ token: CKServerChangeToken, for tokenType: NotificationTokenType) {
        let box = TokenBox(token)
        tokenCache.withLock { cache in
            cache[tokenType] = box
        }
    }

    private func persist(_ token: CKServerChangeToken, for tokenType: NotificationTokenType) {
        let box = TokenBox(token)
        tokenCache.withLock { _ in
            do {
                try notificationTokenHelper.write(box.token, for: tokenType)
            } catch {
                logger.log("Failed to write \(tokenType.rawValue, privacy: .public) token: token=\(box.token, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func persistLastCachedToken(for tokenType: NotificationTokenType) {
        tokenCache.withLock { cache in
            guard let box = cache[tokenType] else {
                return
            }
            do {
                try notificationTokenHelper.write(box.token, for: tokenType)
            } catch {
                logger.log("Failed to write \(tokenType.rawValue, privacy: .public) token: lastToken=\(box.token, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func addDatabaseChangesOperation(database: CKDatabase, completionHandler: @escaping (Result<CKRecord, Error>) -> Void) -> Void {
        self.logger.log("Adding a database change operation for database=\(database, privacy: .public)")

        let dbChangesOperation = CKFetchDatabaseChangesOperation(previousServerChangeToken: lastToken(for: .server))

        dbChangesOperation.recordZoneWithIDChangedBlock = {
            self.addZoneChangesOperation(database: database, zoneId: $0, completionHandler: completionHandler)
        }

        dbChangesOperation.changeTokenUpdatedBlock = { token in
            self.cache(token, for: .server)
        }

        dbChangesOperation.fetchDatabaseChangesResultBlock = { result in
            switch result {
            case .success((let token, _)):
                self.persist(token, for: .server)
            case .failure(let error):
                self.logger.log("Failed to fetch database changes: \(String(describing: error))")
                self.persistLastCachedToken(for: .server)
            }
        }

        dbChangesOperation.qualityOfService = .utility
        database.add(dbChangesOperation)
    }

    private func addZoneChangesOperation(database: CKDatabase, zoneId: CKRecordZone.ID, completionHandler: @escaping (Result<CKRecord, Error>) -> Void) -> Void {
        var configurations = [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]()
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = lastToken(for: .zone)
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
            if let token {
                self.cache(token, for: .zone)
            }
        }

        zoneChangesOperation.recordZoneFetchResultBlock = { recordZoneID, result in
            switch(result) {
            case .success((let serverToken, _, _)):
                self.persist(serverToken, for: .zone)
            case .failure(let error):
                self.logger.log("Failed to fetch zone changes: recordZoneID=\(recordZoneID, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
                self.persistLastCachedToken(for: .zone)
            }
        }

        zoneChangesOperation.qualityOfService = .utility
        database.add(zoneChangesOperation)
    }
}
