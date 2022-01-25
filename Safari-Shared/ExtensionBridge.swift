// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

struct ExtensionBridge {
    
    private static let defaults = UserDefaults(suiteName: "group.io.balance")
    
    private static func key(id: Int) -> String {
        return String(id)
    }
    
    private static var initiatedRequests: Set<Int> {
        get {
            Set(defaults?.array(forKey: "initiatedRequests") as? [Int] ?? [])
        }
        set {
            defaults?.set(Array(newValue), forKey: "initiatedRequests")
        }
    }
    
    static func makeRequest(id: Int) {
        initiatedRequests.insert(id)
    }
    
    static func hasRequest(id: Int) -> Bool {
        if initiatedRequests.contains(id) {
            initiatedRequests.remove(id)
            return true
        } else {
            return false
        }
    }
    
    static func respond(id: Int, response: ResponseToExtension) {
        defaults?.setCodable(response, forKey: key(id: id))
    }
    
    static func removeResponse(id: Int) {
        let key = key(id: id)
        defaults?.removeObject(forKey: key)
    }
    
    static func getResponse(id: Int) -> ResponseToExtension? {
        let key = key(id: id)
        if let response = defaults?.codableValue(type: ResponseToExtension.self, forKey: key) {
            return response
        } else {
            return nil
        }
    }
    
}
