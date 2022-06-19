//
//  File.swift
//  
//
//  Created by Jae Seung Lee on 6/19/22.
//

import Foundation
import CoreData
import os

// Reference: https://williamboles.me/progressive-core-data-migration/
public class DatabaseMigrator: NSObject {
    let logger = Logger()
    
    let sourceModelURL: URL
    let destinationModelURL: URL
    let storeURL: URL
    
    public init(sourceModelURL: URL, destinationModelURL: URL, storeURL: URL ) {
        self.sourceModelURL = sourceModelURL
        self.destinationModelURL = destinationModelURL
        self.storeURL = storeURL
        
        super.init()
    }
    
    private var _sourceModel: NSManagedObjectModel?
    var sourceModel: NSManagedObjectModel? {
        if _sourceModel == nil {
            _sourceModel = NSManagedObjectModel(contentsOf: sourceModelURL)
        }
        return _sourceModel
    }
    
    private var _destinationModel: NSManagedObjectModel?
    var destinationModel: NSManagedObjectModel? {
        if _destinationModel == nil {
            _destinationModel = NSManagedObjectModel(contentsOf: destinationModelURL)
        }
        return _destinationModel
    }
    
    private func sourceMetadata(storeURL: URL) -> [String: Any]? {
        return try? NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: storeURL, options: nil)
    }
    
    public func isMigrationNecessary() -> Bool {
        guard self.sourceModel != nil, let destinationModel = self.destinationModel else {
            return false
        }
        
        guard let sourceMetaData = self.sourceMetadata(storeURL: storeURL) else {
            return false
        }
      
        return !destinationModel.isConfiguration(withName: nil, compatibleWithStoreMetadata: sourceMetaData)
    }
    
    public func migrate(completionHandler: @escaping (Result<Void, Error>) -> Void) -> Void {
        guard let sourceModel = self.sourceModel, let destinationModel = self.destinationModel else {
            return
        }
        
        forceWALCheckpointingForStore(at: storeURL) { error in
            completionHandler(.failure(error))
        }
        
        let temporaryDestinationURL = temporaryDirectory.appendingPathComponent(storeURL.lastPathComponent)
        
        let migrationManager = NSMigrationManager(sourceModel: sourceModel, destinationModel: destinationModel)
        let mappingModel = NSMappingModel(from: nil, forSourceModel: sourceModel, destinationModel: destinationModel)
        
        do {
            try migrationManager.migrateStore(from: storeURL, type: .sqlite, options: nil, mapping: mappingModel!, to: temporaryDestinationURL, type: .sqlite, options: nil)
        } catch {
            logger.error("Cannot migrate persistent stores from \(self.storeURL, privacy: .public) to \(temporaryDestinationURL, privacy: .public) with using \(mappingModel.debugDescription, privacy: .public): \(error.localizedDescription, privacy: .public)")
            completionHandler(.failure(error))
        }
        
        replaceStore(at: storeURL, with: temporaryDestinationURL)
        destoryStore(at: temporaryDestinationURL)
        
        _sourceModel = nil
        _destinationModel = nil
        
        completionHandler(.success(()))
    }
    
    private func forceWALCheckpointingForStore(at storeURL: URL, completionHandler: @escaping (Error) -> Void) {
        let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: storeURL, options: nil)
        
        guard let metadata = metadata, let currentModel = compatibleModelForStoreMetadata(metadata) else {
            return
        }

        do {
            let persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: currentModel)
            let options = [NSSQLitePragmasOption: ["journal_mode": "DELETE"]]
            let store = try persistentStoreCoordinator.addPersistentStore(type: .sqlite, at: storeURL, options: options)
            try persistentStoreCoordinator.remove(store)
        } catch {
            logger.error("failed to force WAL checkpointing: \(error.localizedDescription, privacy: .public)")
            completionHandler(error)
        }
    }
    
    private func compatibleModelForStoreMetadata(_ metadata: [String : Any]) -> NSManagedObjectModel? {
        if let sourceModel = self.sourceModel, sourceModel.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) {
            return sourceModel
        } else {
            return nil
        }
    }
    
    private var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory
    }
    
    private func replaceStore(at storeURL: URL, with replacingStoreURL: URL) {
        do {
            let persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: NSManagedObjectModel())
            try persistentStoreCoordinator.replacePersistentStore(at: storeURL, destinationOptions: nil, withPersistentStoreFrom: replacingStoreURL, sourceOptions: nil, type: .sqlite)
            
        } catch {
            if let error = error as NSError? {
                logger.error("failed to replace persistent store at \(storeURL, privacy: .public) with \(replacingStoreURL, privacy: .public), error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    private func destoryStore(at storeURL: URL) {
        do {
            let persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: NSManagedObjectModel())
            try persistentStoreCoordinator.destroyPersistentStore(at: storeURL, type: .sqlite, options: nil)
        } catch {
            if let error = error as NSError? {
                logger.error("failed to destroy persistent store at \(storeURL, privacy: .public), error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
}
