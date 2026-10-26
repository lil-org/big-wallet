import Foundation
import Security
import Synchronization
import WalletDomain
import XCTest
@testable import WalletAuthority

@MainActor
func assertWalletReload(_ manager: WalletsManager, succeeds: Bool = true, file: StaticString = #filePath, line: UInt = #line) async {
    let loaded = await manager.reloadFromStore()
    XCTAssertEqual(loaded, succeeds, file: file, line: line)
}

final class KeychainCopyMatchingStub: Sendable {
    private static let walletPrefix = "org.lil.wallet.wallet."
    private static let passwordKey = "org.lil.wallet.password"

    private struct Attribute: Sendable {
        let account: String?
        let createdAt: Date?

        var dictionary: [String: Any] {
            var result = [String: Any]()
            result[kSecAttrAccount as String] = account
            result[kSecAttrCreationDate as String] = createdAt
            return result
        }
    }

    private struct State: Sendable {
        var attributes = [Attribute]()
        var attributesStatus = errSecSuccess
        var passwordData: Data?
        var passwordReadCount = 0
        var walletData = [String: Data]()
        var walletReadCount = 0
        var walletReadStatuses = [String: OSStatus]()
    }

    private let state = Mutex(State())

    var attributes: [[String: Any]] {
        get { state.withLock { $0.attributes }.map(\.dictionary) }
        set {
            let attributes = newValue.map { Attribute(account: $0[kSecAttrAccount as String] as? String, createdAt: $0[kSecAttrCreationDate as String] as? Date) }
            state.withLock { $0.attributes = attributes }
        }
    }

    var attributesStatus: OSStatus {
        get { state.withLock { $0.attributesStatus } }
        set { state.withLock { $0.attributesStatus = newValue } }
    }

    var passwordData: Data? {
        get { state.withLock { $0.passwordData } }
        set { state.withLock { $0.passwordData = newValue } }
    }

    var passwordReadCount: Int { state.withLock { $0.passwordReadCount } }

    var walletData: [String: Data] {
        get { state.withLock { $0.walletData } }
        set { state.withLock { $0.walletData = newValue } }
    }

    var walletReadCount: Int { state.withLock { $0.walletReadCount } }

    var walletReadStatuses: [String: OSStatus] {
        get { state.withLock { $0.walletReadStatuses } }
        set { state.withLock { $0.walletReadStatuses = newValue } }
    }

    func walletAttributes(id: String, createdAt: Date? = nil) -> [String: Any] {
        Attribute(account: Self.walletPrefix + id, createdAt: createdAt).dictionary
    }

    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        let query = query as NSDictionary
        return state.withLock { state in
            if query[kSecReturnAttributes as String] as? Bool == true {
                guard state.attributesStatus == errSecSuccess else { return state.attributesStatus }
                result?.pointee = state.attributes.map(\.dictionary) as CFArray
                return errSecSuccess
            }
            guard let key = query[kSecAttrAccount as String] as? String else { return errSecItemNotFound }
            if key == Self.passwordKey {
                state.passwordReadCount += 1
                guard let passwordData = state.passwordData else { return errSecItemNotFound }
                result?.pointee = passwordData as CFData
                return errSecSuccess
            }
            guard key.hasPrefix(Self.walletPrefix) else { return errSecItemNotFound }
            state.walletReadCount += 1
            let id = String(key.dropFirst(Self.walletPrefix.count))
            if let status = state.walletReadStatuses[id], status != errSecSuccess { return status }
            guard let data = state.walletData[id] else { return errSecItemNotFound }
            result?.pointee = data as CFData
            return errSecSuccess
        }
    }
}
