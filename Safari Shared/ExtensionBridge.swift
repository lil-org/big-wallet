// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

struct ExtensionBridge {
    
    private static let defaults = UserDefaults(suiteName: "group.io.tokenary")
    
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
            removeRequest(id: id)
            return true
        } else {
            return false
        }
    }
    
    static func respond(response: ResponseToExtension) {
        defaults?.set(response.json, forKey: key(id: response.id))
    }
    
    static func removeRequest(id: Int) {
        initiatedRequests.remove(id)
    }
    
    static func removeResponse(id: Int) {
        let key = key(id: id)
        defaults?.removeObject(forKey: key)
    }
    
    static func getResponse(id: Int) -> [String: AnyHashable]? {
        let key = key(id: id)
        return defaults?.value(forKey: key) as? [String: AnyHashable]
    }
    
}
