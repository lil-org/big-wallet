// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation

struct Keychain {
    
    private init() {}
    
    static let shared = Keychain()
    
    private enum ItemKey {
        
        static let commonPrefix = "ink.encrypted.macos."
        static let walletPrefix = "wallet."
        
        case accounts
        case password
        case wallet(id: String)
        
        var stringValue: String {
            let key: String
            switch self {
            case .accounts:
                key = "ethereum.keys"
            case .password:
                key = "password"
            case let .wallet(id: id):
                key = ItemKey.walletPrefix + id
            }
            return ItemKey.commonPrefix + key
        }
        
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
    
    // MARK: - Legacy
    
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
        return get(key: .wallet(id: id))
    }
    
    func saveWallet(id: String, data: Data) throws {
        save(data: data, key: .wallet(id: id))
    }
    
    func removeWallet(id: String) throws {
        removeData(forKey: .wallet(id: id))
    }
    
    func removeAllWallets() throws {
        for id in getAllWalletsIds() {
            removeData(forKey: .wallet(id: id))
        }
    }
    
    // MARK: Private
    
    private func save(data: Data, key: ItemKey) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: key.stringValue,
                                    kSecValueData as String: data]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    private func allStoredItemsKeys() -> [String] {
        return []
    }
    
    private func removeData(forKey key: ItemKey) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                     kSecAttrAccount as String: key.stringValue]
        SecItemDelete(query as CFDictionary)
    }
    
    private func get(key: ItemKey) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: key.stringValue,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &item)
        if status == noErr, let data = item as? Data {
            return data
        } else {
            return nil
        }
    }
    
}
