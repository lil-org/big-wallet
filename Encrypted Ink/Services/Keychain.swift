// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation

struct Keychain {
    
    private let prefix = "ink.encrypted.macos."
    
    private init() {}
    
    static let shared = Keychain()
    
    private enum Key: String {
        case accounts = "ethereum.keys"
        case password = "password"
    }
    
    var password: String? {
        if let data = get(key: .password), let password = String(data: data, encoding: .utf8) {
            return password
        } else {
            return nil
        }
    }
    
    func save(password: String) {
        guard let data = password.data(using: .utf8) else { return }
        save(data: data, key: .password)
    }
    
    var accounts: [AccountWithKey] {
        if let data = get(key: .accounts), let accounts = try? JSONDecoder().decode([AccountWithKey].self, from: data) {
            return accounts
        } else {
            return []
        }
    }
    
    func save(accounts: [AccountWithKey]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        save(data: data, key: .accounts)
    }
    
    // MARK: - WalletCore
    
    func getAllWalletsIds() -> [String] {
        // TODO: implement
        return []
    }
    
    func getWalletData(id: String) -> Data? {
        // TODO: implement
        return nil
    }
    
    func saveWallet(id: String, data: Data) throws {
        // TODO: implement
    }
    
    func removeWallet(id: String) throws {
        // TODO: implement
    }
    
    func removeAllWallets() throws {
        // TODO: implement
    }
    
    // MARK: Private
    
    private func save(data: Data, key: Key) {
        let query = [kSecClass as String: kSecClassGenericPassword as String,
                     kSecAttrAccount as String: prefix + key.rawValue,
                     kSecValueData as String: data] as [String: Any]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    private func get(key: Key) -> Data? {
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
