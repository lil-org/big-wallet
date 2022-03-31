// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

public struct Constants {
    // MARK: - Public Properties

    public static var isDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
    
    public static var identifier: String {
        Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? .empty
    }
    
    public static var name: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? .empty
    }
    
    public static var shortVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? .empty
    }
    
    public static let currentKeychainMigrationVersion: String = "0.0.1"

    // MARK: - Schemes

    public static let tokenarySchemePrefix = "tokenary://"
}
