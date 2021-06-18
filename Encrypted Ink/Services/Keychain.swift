// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation

struct Keychain {
    
    private static let prefix = "ink.encrypted.macos."
    
    private enum Key: String {
        case accounts = "ethereum.keys"
        case password = "password"
    }
    
    static var password: String? {
        if let data = get(key: .password), let password = String(data: data, encoding: .utf8) {
            return password
        } else {
            return nil
        }
    }
    
    static func save(password: String) {
        guard let data = password.data(using: .utf8) else { return }
        save(data: data, key: .password)
    }
    
    static var accounts: [Account] {
        if let data = get(key: .accounts), let accounts = try? JSONDecoder().decode([Account].self, from: data) {
            return accounts
        } else {
            return []
        }
    }
    
    static func save(accounts: [Account]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        save(data: data, key: .accounts)
    }
    
    // MARK: Private
    
    private static func save(data: Data, key: Key) {
        let query = [kSecClass as String: kSecClassGenericPassword as String,
                     kSecAttrAccount as String: prefix + key.rawValue,
                     kSecValueData as String: data] as [String: Any]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    private static func get(key: Key) -> Data? {
        guard let returnDataQueryValue = kCFBooleanTrue else { return nil }
        let query = [kSecClass as String: kSecClassGenericPassword,
                     kSecAttrAccount as String: prefix + key.rawValue,
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
