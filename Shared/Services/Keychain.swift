// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

struct Keychain {
    
    enum KeychainError: Error {
        case failedToUpdate
    }
    
    private init() {}
    
    static let shared = Keychain()
    
    private enum ItemKey {
        case password
        case wallet(id: String)
        case raw(key: String)
        
        private static let commonPrefix = "io.tokenary.macos."
        private static let walletPrefix = "wallet."
        private static let fullWalletPrefix = commonPrefix + walletPrefix
        private static let fullWalletPrefixCount = fullWalletPrefix.count
        
        var stringValue: String {
            switch self {
            case .password:
                return ItemKey.commonPrefix + "password"
            case let .wallet(id: id):
                return ItemKey.commonPrefix + ItemKey.walletPrefix + id
            case let .raw(key: key):
                return key
            }
        }
        
        static func walletId(key: String) -> String? {
            guard key.hasPrefix(fullWalletPrefix) else { return nil }
            return String(key.dropFirst(fullWalletPrefixCount))
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
    
    func updateWallet(id: String, data: Data) throws {
        try update(data: data, key: .wallet(id: id))
    }
    
    func removeWallet(id: String) throws {
        removeData(forKey: .wallet(id: id))
    }
    
    func removeAllWallets() throws {
        for id in getAllWalletsIds() {
            removeData(forKey: .wallet(id: id))
        }
    }
    
    // MARK: - Private
    
    private func update(data: Data, key: ItemKey) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: key.stringValue]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError.failedToUpdate }
    }
    
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
            let sorted = items.sorted(by: { ($0[kSecAttrCreationDate as String] as? Date ?? Date()) < ($1[kSecAttrCreationDate as String] as? Date ?? Date()) })
            return sorted.compactMap { $0[kSecAttrAccount as String] as? String }
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
