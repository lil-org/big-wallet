// ∅ 2026 lil org

import Foundation

struct Keychain {

    typealias CopyMatching = (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus

    enum KeychainError: Error {
        case failedToRead(OSStatus)
        case failedToSave(OSStatus)
        case failedToUpdate
        case failedToDelete(OSStatus)
    }
    
    private let copyMatching: CopyMatching

    init(copyMatching: @escaping CopyMatching = SecItemCopyMatching) {
        self.copyMatching = copyMatching
    }
    
    static let shared = Keychain()
    
    private let accessGroup = "8DXC3N7E7P.org.lil.keychain"
    
    private enum ItemKey {
        case password
        case wallet(id: String)
        case raw(key: String)
        
        private static let commonPrefix = "org.lil.wallet."
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
    
    func readPasswordData() throws -> Data? {
        try read(key: .password)
    }

    @discardableResult
    func save(password: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
#if os(iOS) || os(visionOS)
        do {
            try SafariApprovalVaultHost.shared.performSourceMutation {
                try save(data: data, key: .password)
            }
            return true
        } catch {
            return false
        }
#else
        do {
            try save(data: data, key: .password)
            return true
        } catch {
            return false
        }
#endif
    }

    func createPasswordIfMissing(_ password: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
#if os(iOS) || os(visionOS)
        return (try? SafariApprovalVaultHost.shared.performSourceMutation {
            saveIfMissing(data: data, key: .password)
        }) ?? false
#else
        return saveIfMissing(data: data, key: .password)
#endif
    }

    func readAllWalletIDs() throws -> [String] {
        let items = try allStoredItemAttributes()
        let missingCreationDate = Date.distantFuture
        let wallets = items.compactMap { item -> (id: String, createdAt: Date)? in
            guard let key = item[kSecAttrAccount as String] as? String,
                  let id = ItemKey.walletId(key: key) else { return nil }
            return (
                id: id,
                createdAt: item[kSecAttrCreationDate as String] as? Date ?? missingCreationDate
            )
        }
        return wallets.sorted { left, right in
            if left.createdAt != right.createdAt {
                return left.createdAt < right.createdAt
            }
            return left.id < right.id
        }.map(\.id)
    }
    
    func getWalletData(id: String) -> Data? {
        return try? readWalletData(id: id)
    }

    func readWalletData(id: String) throws -> Data? {
        return try read(key: .wallet(id: id))
    }
    
    func saveWallet(id: String, data: Data) throws {
        try save(data: data, key: .wallet(id: id))
    }
    
    func updateWallet(id: String, data: Data) throws {
        try update(data: data, key: .wallet(id: id))
    }
    
    func removeWallet(id: String) throws {
        try removeData(forKey: .wallet(id: id))
    }
    
    private func update(data: Data, key: ItemKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.stringValue,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError.failedToUpdate }
    }
    
    private func save(data: Data, key: ItemKey) throws {
        let query = saveQuery(data: data, key: key)
        var deleteQuery = query
        deleteQuery[kSecValueData as String] = nil
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        guard deleteStatus == errSecSuccess ||
                deleteStatus == errSecItemNotFound else {
            throw KeychainError.failedToSave(deleteStatus)
        }
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.failedToSave(addStatus)
        }
    }

    private func saveIfMissing(data: Data, key: ItemKey) -> Bool {
        let query = saveQuery(data: data, key: key)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private func saveQuery(data: Data, key: ItemKey) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.stringValue,
            kSecValueData as String: data,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
    
    private func allStoredItemAttributes() throws -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnData as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true
        ]
        var items: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess,
              let items = items as? [[String: Any]] else {
            throw KeychainError.failedToRead(
                status == errSecSuccess ? errSecDecode : status
            )
        }
        return items
    }
    
    private func removeData(forKey key: ItemKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.stringValue,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.failedToDelete(status)
        }
    }
    
    private func get(key: ItemKey) -> Data? {
        return try? read(key: key)
    }

    private func read(key: ItemKey) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.stringValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true
        ]
        var item: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.failedToRead(
                status == errSecSuccess ? errSecDecode : status
            )
        }
        return data
    }
    
    
}
