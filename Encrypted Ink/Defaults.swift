// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation

struct Defaults {
 
    private static let userDefaults = UserDefaults.standard

    static var storedSessions: [String: SessionStorage.Item] {
        get {
            return userDefaults.codableValue(type: [String: SessionStorage.Item].self, forKey: "storedSessions") ?? [:]
        }
        set {
            userDefaults.setCodable(newValue, forKey: "storedSessions")
        }
    }
    
}
