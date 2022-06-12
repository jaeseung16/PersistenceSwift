//
//  File.swift
//  
//
//  Created by Jae Seung Lee on 6/6/22.
//

import Foundation
import CoreData
import os

public class HistoryToken {
    private static let logger = Logger()
    
    private static let pathComponent = "token.data"
    
    private var appPathComponent: String
    
    var last: NSPersistentHistoryToken? = nil {
        didSet {
            guard let token = last,
                  let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else {
                return
            }
            
            do {
                try data.write(to: tokenFile)
            } catch {
                HistoryToken.logger.log("Could not write history token data: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    private lazy var tokenFile: URL = {
        let url = NSPersistentContainer.defaultDirectoryURL().appendingPathComponent(appPathComponent, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url,
                                                        withIntermediateDirectories: true,
                                                        attributes: nil)
            } catch {
                HistoryToken.logger.log("Could not create token file at \(url): \(error.localizedDescription)")
            }
        }
        return url.appendingPathComponent(HistoryToken.pathComponent, isDirectory: false)
    }()
    
    public init(appPathComponent: String) {
        self.appPathComponent = appPathComponent
        
        if let data = try? Data(contentsOf: tokenFile) {
            self.last = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? NSPersistentHistoryToken
        }
    }
}
