//
//  File.swift
//  
//
//  Created by Jae Seung Lee on 6/6/22.
//

import Foundation
import CoreData
import os

public actor HistoryToken {
    private static let logger = Logger()
    
    private static let pathComponent = "token.data"
    
    private let appPathComponent: String
    private let tokenFile: URL
    
    private var last: NSPersistentHistoryToken?
    
    private static func tokenFileURL(_ appPathComponent: String) -> URL {
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
    }
    
    public init(appPathComponent: String) {
        self.appPathComponent = appPathComponent
        self.tokenFile = HistoryToken.tokenFileURL(appPathComponent)
        
        if let data = try? Data(contentsOf: tokenFile) {
            self.last = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data)
        }
    }
    
    public func getToken() -> NSPersistentHistoryToken? {
        return last
    }

    public func setToken(_ historyToken: NSPersistentHistoryToken?) -> Void {
        last = historyToken
        
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
