import Foundation
import Security
import Synchronization
import XCTest
import WalletDomain
@testable import WalletAuthority
import LocalAuthentication

final class PasswordKeychainFixture: Sendable {
    private struct State {
        var passwordData: Data?
        var readStatus: OSStatus?
        var inventoryStatus: OSStatus?
        var addStatus: OSStatus?
        var wrongReturnType = false
        var walletIDs = [String]()
        var passwordReadCount = 0
        var addCount = 0
        var deleteCount = 0
        var updateCount = 0
    }

    private let state = Mutex(State())

    var passwordData: Data? {
        get { state.withLock { $0.passwordData } }
        set { state.withLock { $0.passwordData = newValue } }
    }
    var readStatus: OSStatus? {
        get { state.withLock { $0.readStatus } }
        set { state.withLock { $0.readStatus = newValue } }
    }
    var inventoryStatus: OSStatus? {
        get { state.withLock { $0.inventoryStatus } }
        set { state.withLock { $0.inventoryStatus = newValue } }
    }
    var addStatus: OSStatus? {
        get { state.withLock { $0.addStatus } }
        set { state.withLock { $0.addStatus = newValue } }
    }
    var wrongReturnType: Bool {
        get { state.withLock { $0.wrongReturnType } }
        set { state.withLock { $0.wrongReturnType = newValue } }
    }
    var walletIDs: [String] {
        get { state.withLock { $0.walletIDs } }
        set { state.withLock { $0.walletIDs = newValue } }
    }
    var addCount: Int { state.withLock { $0.addCount } }
    var deleteCount: Int { state.withLock { $0.deleteCount } }
    var updateCount: Int { state.withLock { $0.updateCount } }
    var passwordReadCount: Int { state.withLock { $0.passwordReadCount } }


    var credentials: WalletCredentials {
#if os(iOS) || os(visionOS)
        let vault = SafariApprovalVault(fileURL: nil, keyStore: PasswordFixtureApprovalKeys())
        let host = SafariApprovalVaultHost(vault: vault, integrityKeyStore: PasswordFixtureIntegrityKey()) { nil }
        return WalletCredentials(keychain: keychain, messages: .testingEnglish, authorityID: UUID(), vaultHost: host)
#else
        return WalletCredentials(keychain: keychain, messages: .testingEnglish, authorityID: UUID())
#endif
    }

    func verify(password: String) throws -> Bool {
        let credentials = credentials
        let challenge = credentials.makeWalletAccessChallenge()
        defer { challenge.invalidate() }
        return try credentials.verify(password: password, challenge: challenge) != nil
    }

    var keychain: Keychain {
        Keychain(copyMatching: { [self] query, output in
            let query = query as NSDictionary
            return state.withLock { state in
                if query[kSecAttrAccount as String] as? String == "org.lil.wallet.password" {
                    state.passwordReadCount += 1
                    if let status = state.readStatus { return status }
                    if state.wrongReturnType {
                        output?.pointee = "unexpected" as CFString
                        return errSecSuccess
                    }
                    guard let data = state.passwordData else { return errSecItemNotFound }
                    output?.pointee = data as CFData
                    return errSecSuccess
                }
                if let status = state.inventoryStatus { return status }
                guard !state.walletIDs.isEmpty else { return errSecItemNotFound }
                output?.pointee = state.walletIDs.map {
                    [kSecAttrAccount as String: "org.lil.wallet.wallet." + $0]
                } as CFArray
                return errSecSuccess
            }
        }, add: { [self] query, _ in
            let query = query as NSDictionary
            return state.withLock { state in
                state.addCount += 1
                if let status = state.addStatus { return status }
                guard state.passwordData == nil else { return errSecDuplicateItem }
                guard let data = query[kSecValueData as String] as? Data else { return errSecParam }
                state.passwordData = data
                return errSecSuccess
            }
        }, update: { [self] _, _ in
            state.withLock { $0.updateCount += 1 }
            return errSecSuccess
        }, delete: { [self] _ in
            state.withLock { $0.deleteCount += 1 }
            return errSecSuccess
        })
    }
}

#if os(iOS) || os(visionOS)
private final class PasswordFixtureApprovalKeys: SafariApprovalKeyStoring, Sendable {
    func store(_ key: SecretBytes, identity: SafariApprovalKeyIdentity) throws { throw SafariApprovalVault.Error.unavailable }
    func load(identity: SafariApprovalKeyIdentity, context: LAContext) throws -> SecretBytes { throw SafariApprovalVault.Error.unavailable }
    func availability(identities: [SafariApprovalKeyIdentity]) -> [SafariApprovalKeyIdentity: SafariApprovalKeyAvailability] { [:] }
    func removeAll() throws {}
}

private final class PasswordFixtureIntegrityKey: SafariApprovalIntegrityKeyStoring, Sendable {
    func loadOrCreate() throws -> SecretBytes { throw SafariApprovalVault.Error.unavailable }
}
#endif
