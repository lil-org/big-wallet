// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation

struct Defaults {
 
    private static let userDefaults = UserDefaults.standard

    static var storedSessions: [SessionStorage.Item] {
        get {
            return userDefaults.codableValue(type: [SessionStorage.Item].self, forKey: "storedSessions") ?? []
        }
        set {
            userDefaults.setCodable(newValue, forKey: "storedSessions")
        }
    }
    
}
