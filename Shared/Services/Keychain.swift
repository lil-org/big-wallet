// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

struct Keychain {
    
    private init() {}
    
    static let shared = Keychain()
    
    private enum ItemKey {
        case password
        case wallet(id: String)
        case legacyPassword
        case raw(key: String)
        
        private static let commonPrefix = "io.tokenary.macos."
        private static let walletPrefix = "wallet."
        private static let fullWalletPrefix = commonPrefix + walletPrefix
        private static let fullWalletPrefixCount = fullWalletPrefix.count
        private static let legacyWalletPrefix = "io.tokenary.accountstorage."
        
        var stringValue: String {
            switch self {
            case .password:
                return ItemKey.commonPrefix + "password"
            case let .wallet(id: id):
                return ItemKey.commonPrefix + ItemKey.walletPrefix + id
            case .legacyPassword:
                return "io.tokenary.local.passphrase"
            case let .raw(key: key):
                return key
            }
        }
        
        static func walletId(key: String) -> String? {
            guard key.hasPrefix(fullWalletPrefix) else { return nil }
            return String(key.dropFirst(fullWalletPrefixCount))
        }
        
        static func isLegacyWallet(key: String) -> Bool {
            return key.hasPrefix(legacyWalletPrefix)
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
    
    // MARK: - WalletCore
    
    func getAllWalletsIds() -> [String] {
        let allKeys = allStoredItemsKeys()
        let ids = allKeys.compactMap { ItemKey.walletId(key: $0) }
        return ids
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
    
    // MARK: - Migration
    
    func getLegacyKeystores() -> [Data] {
        return allStoredItemsKeys().filter { ItemKey.isLegacyWallet(key: $0) }.compactMap { get(key: .raw(key: $0)) }
    }
    
    var legacyPassword: String? {
        if let data = get(key: .legacyPassword), let password = String(data: data, encoding: .utf8) {
            return password
        } else {
            return nil
        }
    }
    
    // MARK: - Private
    
    private func save(data: Data, key: ItemKey) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: key.stringValue,
                                    kSecValueData as String: data]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    private func allStoredItemsKeys() -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecReturnData as String: false,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        var items: CFTypeRef?
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &items)
        if status == noErr, let items = items as? [[String: Any]], !items.isEmpty {
            return items.compactMap { $0[kSecAttrAccount as String] as? String }
        } else {
            return []
        }
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
