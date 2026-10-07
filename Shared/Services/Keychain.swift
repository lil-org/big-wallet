// ∅ 2026 lil org

import Foundation

struct Keychain: Sendable {

    typealias CopyMatching = @Sendable (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    typealias Add = @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    typealias Update = @Sendable (CFDictionary, CFDictionary) -> OSStatus
    typealias Delete = @Sendable (CFDictionary) -> OSStatus

    enum KeychainError: Error {
        case failedToRead(OSStatus)
        case failedToSave(OSStatus)
        case failedToUpdate
        case failedToDelete(OSStatus)
        case invalidPasswordData
        case orphanedWallets
    }

    enum PasswordState: Equatable, Sendable { case missing, present }
    enum PasswordCreationResult: Equatable, Sendable { case created, alreadyExists }
    
    private let copyMatching: CopyMatching
    private let add: Add
    private let update: Update
    private let delete: Delete

    init(
        copyMatching: @escaping CopyMatching = SecItemCopyMatching,
        add: @escaping Add = SecItemAdd,
        update: @escaping Update = SecItemUpdate,
        delete: @escaping Delete = SecItemDelete
    ) {
        self.copyMatching = copyMatching
        self.add = add
        self.update = update
        self.delete = delete
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
    
    func readPassword() throws -> String? {
        guard let data = try read(key: .password) else { return nil }
        guard let password = String(data: data, encoding: .utf8), !password.isEmpty else {
            throw KeychainError.invalidPasswordData
        }
        return password
    }
    
    func readPasswordData() throws -> Data? {
        try readPassword().map { Data($0.utf8) }
    }

    func passwordState() throws -> PasswordState {
        if try readPasswordData() != nil { return .present }
        guard try readAllWalletIDs().isEmpty else { throw KeychainError.orphanedWallets }
        return .missing
    }

    func createPasswordIfMissing(_ password: String) async throws -> PasswordCreationResult {
        let result: PasswordCreationResult
#if os(iOS) || os(visionOS)
        result = try await SafariApprovalVaultHost.shared.performSourceMutation { willMutateSource in
            try createPasswordIfMissing(password, beforeInsert: willMutateSource)
        }
#else
        result = try createPasswordIfMissing(password, beforeInsert: {})
#endif
        return result
    }

    func createPasswordIfMissing(
        _ password: String,
        beforeInsert: () throws -> Void
    ) throws -> PasswordCreationResult {
        try Task.checkCancellation()
        guard password.isOkAsPassword else { throw KeychainError.invalidPasswordData }
        guard try passwordState() == .missing else { return .alreadyExists }
        try Task.checkCancellation()
        try beforeInsert()
        try Task.checkCancellation()
        let status = add(saveQuery(data: Data(password.utf8), key: .password) as CFDictionary, nil)
        switch status {
        case errSecSuccess: return .created
        case errSecDuplicateItem: return .alreadyExists
        default: throw KeychainError.failedToSave(status)
        }
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
        let status = update(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError.failedToUpdate }
    }
    
    private func save(data: Data, key: ItemKey) throws {
        let query = saveQuery(data: data, key: key)
        var deleteQuery = query
        deleteQuery[kSecValueData as String] = nil
        let deleteStatus = delete(deleteQuery as CFDictionary)
        guard deleteStatus == errSecSuccess ||
                deleteStatus == errSecItemNotFound else {
            throw KeychainError.failedToSave(deleteStatus)
        }
        let addStatus = add(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.failedToSave(addStatus)
        }
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
        let status = delete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.failedToDelete(status)
        }
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
