// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation

struct Keychain {
    
    private static let prefix = "ink.encrypted.macos."
    
    private struct Key {
        static let accounts = "ethereum.keys"
        static let password = "password"
    }
    
    static var password: String? {
        return "" // TODO: implement
    }
    
    static func save(password: String) {
        // TODO: implement
    }
    
    static var accounts: [Account] {
        if let data = get(key: Key.accounts), let accounts = try? JSONDecoder().decode([Account].self, from: data) {
            return accounts
        } else {
            return []
        }
    }
    
    static func save(accounts: [Account]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        save(data: data, key: Key.password)
        
    }
    
    // MARK: Private
    
    private static func save(data: Data, key: String) {
        let query = [kSecClass as String: kSecClassGenericPassword as String,
                     kSecAttrAccount as String: prefix + key,
                     kSecValueData as String: data] as [String: Any]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    private static func get(key: String) -> Data? {
        guard let returnDataQueryValue = kCFBooleanTrue else { return nil }
        let query = [kSecClass as String: kSecClassGenericPassword,
                     kSecAttrAccount as String: prefix + key,
                     kSecReturnData as String: returnDataQueryValue,
                     kSecMatchLimit as String: kSecMatchLimitOne] as [String: Any]

        var dataTypeRef: AnyObject?
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == noErr, let data = dataTypeRef as? Data {
            return data
        } else {
            return nil
        }
    }
    
}
