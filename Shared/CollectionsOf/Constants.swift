// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

struct Constants {
    // MARK: - Properties

    static var isDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
    
    static var identifier: String {
        Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? .empty
    }
    
    static var name: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? .empty
    }
    
    static var shortVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? .empty
    }
    
    static let currentKeychainMigrationVersion: String = "0.0.1"

    // MARK: - Schemes

    static let tokenarySchemePrefix = "tokenary://"
}
