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

public class NotificationTokenHelper {
    static private let logger = Logger()
    static private let key = "token"
    
    private let appName: String
    
    public init(appName: String) {
        self.appName = appName
    }
    
    private func url(for tokenType: NotificationTokenType) -> URL {
        let url = NSPersistentContainer.defaultDirectoryURL().appendingPathComponent(appName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url,
                                                        withIntermediateDirectories: true,
                                                        attributes: nil)
            } catch {
                NotificationTokenHelper.logger.log("Could not create persistent container URL for a NotificationToken \(tokenType.rawValue, privacy: .public)")
            }
        }
        return url.appendingPathComponent("\(tokenType.rawValue).data", isDirectory: false)
    }
    
    public func write(_ token: CKServerChangeToken, for tokenType: NotificationTokenType) throws {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        coder.encode(token, forKey: NotificationTokenHelper.key)
        let data = coder.encodedData
        try data.write(to: url(for: tokenType))
    }
    
    public func read(_ tokenType: NotificationTokenType) throws -> CKServerChangeToken? {
        let data = try Data(contentsOf: url(for: tokenType))
        let coder = try NSKeyedUnarchiver(forReadingFrom: data)
        return coder.decodeObject(of: CKServerChangeToken.self, forKey: NotificationTokenHelper.key)
    }
    
}
