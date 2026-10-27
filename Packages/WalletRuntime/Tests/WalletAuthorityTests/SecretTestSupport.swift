import Foundation
import XCTest
import WalletDomain
@testable import WalletAuthority

extension SecretBytes {
    var testData: Data {
        do { return try withUnsafeBytes { Data($0) } }
        catch { XCTFail("Fixture attempted to read retired secret bytes"); return Data() }
    }
}

extension WalletExportedSecret {
    convenience init(text: String) { self.init(bytes: SecretBytes(utf8: text)) }
}

extension Scrypt {
    static func deriveKey(password: Data, salt: Data, n: Int, r: Int, p: Int, dkLen: Int) -> Data {
        let secret = SecretBytes(copying: password)
        defer { secret.invalidate() }
        guard let result = deriveSecret(password: secret, salt: salt, n: n, r: r, p: p, dkLen: dkLen) else { return Data() }
        defer { result.invalidate() }
        return result.testData
    }
}

extension Ed25519 {
    static func sign(message: Data, seed: Data) -> Data? {
        let seed = SecretBytes(copying: seed)
        defer { seed.invalidate() }
        return sign(message: message, seed: seed)
    }

    static func sign<Messages: Sequence>(messages: Messages, seed: Data) -> [Data]? where Messages.Element == Data {
        let seed = SecretBytes(copying: seed)
        defer { seed.invalidate() }
        return sign(messages: messages, seed: seed)
    }
}

extension Secp256k1 {
    static func sign(digest: Data, privateKey: Data) -> Data? {
        let key = SecretBytes(copying: privateKey)
        defer { key.invalidate() }
        return sign(digest: digest, privateKey: key)
    }

    static func addPrivateKey(_ privateKey: Data, tweak: Data) -> Data? {
        let key = SecretBytes(copying: privateKey)
        let tweak = SecretBytes(copying: tweak)
        defer { key.invalidate(); tweak.invalidate() }
        guard let result = addPrivateKey(key, tweak: tweak) else { return nil }
        defer { result.invalidate() }
        return result.testData
    }
}

extension WalletPrivateKey {
    func withData<Value>(_ body: (Data) throws -> Value) rethrows -> Value {
        let data: Data
        do { data = try withUnsafeBytes { Data($0) } }
        catch { XCTFail("Fixture attempted to read a retired private key"); data = Data() }
        return try body(data)
    }
}

extension Keychain {
    func readPasswordData() throws -> Data? {
        guard let password = try readPasswordSecret() else { return nil }
        defer { password.invalidate() }
        return password.testData
    }

    func readPassword() throws -> String? {
        guard let password = try readPasswordSecret() else { return nil }
        defer { password.invalidate() }
        return try password.withUTF8String { $0 }
    }
}

extension WalletStoredKey {
    init?(name: String, password: Data) {
        let secret = SecretBytes(copying: password)
        defer { secret.invalidate() }
        self.init(name: name, password: secret)
    }

    static func importPrivateKey(privateKey: Data, name: String, password: Data, coin: WalletCoin) -> WalletStoredKey? {
        let password = SecretBytes(copying: password)
        defer { password.invalidate() }
        guard let key = WalletPrivateKey(data: privateKey) else { return nil }
        defer { key.invalidate() }
        return importPrivateKey(privateKey: key, name: name, password: password, coin: coin)
    }

    static func importPrivateKey(privateKey: Data, name: String, password: SecretBytes, coin: WalletCoin) -> WalletStoredKey? {
        guard let key = WalletPrivateKey(data: privateKey) else { return nil }
        defer { key.invalidate() }
        return importPrivateKey(privateKey: key, name: name, password: password, coin: coin)
    }

    static func importHDWallet(mnemonic: String, name: String, password: Data, coin: WalletCoin) -> WalletStoredKey? {
        let password = SecretBytes(copying: password)
        defer { password.invalidate() }
        return importHDWallet(mnemonic: mnemonic, name: name, password: password, coin: coin)
    }

    func wallet(password: Data) -> WalletHDWallet? {
        let password = SecretBytes(copying: password)
        defer { password.invalidate() }
        return wallet(password: password)
    }

    func privateKey(coin: WalletCoin, password: Data) -> WalletPrivateKey? {
        let password = SecretBytes(copying: password)
        defer { password.invalidate() }
        return privateKey(coin: coin, password: password)
    }

    func decryptPrivateKey(password: Data) -> Data? {
        let password = SecretBytes(copying: password)
        defer { password.invalidate() }
        guard let secret = decryptPrivateKey(password: password) else { return nil }
        defer { secret.invalidate() }
        return secret.testData
    }

    func decryptMnemonic(password: Data) -> String? {
        let password = SecretBytes(copying: password)
        defer { password.invalidate() }
        guard let secret = decryptMnemonicSecret(password: password) else { return nil }
        defer { secret.invalidate() }
        return String(data: secret.testData, encoding: .utf8)
    }
}

extension WalletContainer {
    func getAccount(password: String, coin: WalletCoin) throws -> WalletAccount {
        let secret = SecretBytes(utf8: password)
        defer { secret.invalidate() }
        return try getAccount(password: secret, coin: coin)
    }

    func privateKey(password: String, account: WalletAccount) throws -> WalletPrivateKey {
        let secret = SecretBytes(utf8: password)
        defer { secret.invalidate() }
        return try privateKey(password: secret, account: account)
    }

    func privateKey(passwordData: Data, account: WalletAccount) throws -> WalletPrivateKey {
        let secret = SecretBytes(copying: passwordData)
        defer { secret.invalidate() }
        return try privateKey(password: secret, account: account)
    }

    func privateKey(passwordData: SecretBytes, account: WalletAccount) throws -> WalletPrivateKey {
        try privateKey(password: passwordData, account: account)
    }
}

extension WalletRepository.Source {
    init(walletID: String, data: Data, password: Data) {
        try! self.init(walletID: walletID, data: data, password: SecretBytes(copying: password))
    }
}

extension WalletRepository {
    func saveNewWallet(_ prepared: PreparedCreation, willMutateSource: @Sendable () throws -> Void) throws -> Change {
        try saveNewWallet(prepared, willMutateSource: willMutateSource, validateAccess: {})
    }

    func delete(_ prepared: PreparedDeletion, willMutateSource: @Sendable () throws -> Void) throws -> Change {
        try delete(prepared, willMutateSource: willMutateSource, validateAccess: {})
    }

    func update(wallet: WalletSnapshot, enabledAccounts: [WalletAccount], willMutateSource: @Sendable () throws -> Void) throws -> Change {
        try update(wallet: wallet, enabledAccounts: enabledAccounts, willMutateSource: willMutateSource, validateAccess: {})
    }

    func update(wallet: WalletSnapshot, removeAccounts: [WalletAccount], willMutateSource: @Sendable () throws -> Void) throws -> Change {
        try update(wallet: wallet, removeAccounts: removeAccounts, willMutateSource: willMutateSource, validateAccess: {})
    }
}

extension SafariApprovalSourceSnapshot {
    init(catalog: WalletAccountCatalog, password: Data, wallets: [SafariApprovalWalletRecord]) {
        self.init(catalog: catalog, password: SecretBytes(copying: password), wallets: wallets)
    }

    func copyForTesting() -> SafariApprovalSourceSnapshot {
        .init(catalog: catalog, password: password.testData, wallets: wallets)
    }
}

extension Optional where Wrapped == SafariApprovalSourceSnapshot {
    func copyForTesting() -> SafariApprovalSourceSnapshot? { map { $0.copyForTesting() } }
}

extension SafariApprovalVault {
    @discardableResult
    func publish(source: SafariApprovalSourceSnapshot, integrityKey: Data,
                 coordinationLease: CoordinationLease? = nil,
                 activity: SafariApprovalReconciliationActivity? = nil) throws -> Publication {
        let key = SecretBytes(copying: integrityKey)
        defer { key.invalidate() }
        return try publish(source: source, integrityKey: key, coordinationLease: coordinationLease, activity: activity)
    }

    func publicationStatus(source: SafariApprovalSourceSnapshot, expectedGeneration: UUID,
                           expectedEnvelopeDigest: Data, expectedSourceMAC: Data, integrityKey: Data) -> PublicationStatus {
        let key = SecretBytes(copying: integrityKey)
        defer { key.invalidate() }
        return publicationStatus(source: source, expectedGeneration: expectedGeneration,
            expectedEnvelopeDigest: expectedEnvelopeDigest, expectedSourceMAC: expectedSourceMAC, integrityKey: key)
    }
}

extension SafariApprovalKeyStoring {
    func store(_ key: Data, identity: SafariApprovalKeyIdentity) throws {
        let secret = SecretBytes(copying: key)
        defer { secret.invalidate() }
        try store(secret, identity: identity)
    }
}

extension EncryptedPayload {
    static func encrypt(payload: Data, password: Data) -> EncryptedPayload? {
        let payload = SecretBytes(copying: payload)
        let password = SecretBytes(copying: password)
        defer { payload.invalidate(); password.invalidate() }
        return encrypt(payload: payload, password: password)
    }

    static func encrypt(payload: SecretBytes, password: Data) -> EncryptedPayload? {
        let password = SecretBytes(copying: password)
        defer { password.invalidate() }
        return encrypt(payload: payload, password: password)
    }
}

func XCTAssertEqual(_ lhs: @autoclosure () throws -> SecretBytes, _ rhs: @autoclosure () throws -> Data,
                    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(try lhs().testData, try rhs(), message(), file: file, line: line)
}

func XCTAssertEqual(_ lhs: @autoclosure () throws -> SecretBytes, _ rhs: @autoclosure () throws -> SecretBytes,
                    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(try lhs().testData, try rhs().testData, message(), file: file, line: line)
}

func walletAccessForTesting(
    authorityID: UUID,
    clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    status: @escaping @Sendable () -> WalletCredentialIdentity.Status = { .current }
) -> WalletAccessSession {
    let challenge = WalletAuthenticationChallenge(authorityID: authorityID, purpose: .walletAccess(UUID()),
        deadline: .distantFuture)
    return challenge.issueGrant(for: authorityID, credentialIdentity: .init(status: status))!
        .accessSession(authorityID: authorityID, accessClock: clock)!
}

@MainActor
extension WalletsManager {
    func accessForTesting() -> WalletAccessSession { walletAccessForTesting(authorityID: authorityID) }

    nonisolated static func privateKeyExportString(privateKey: WalletPrivateKey, coin: WalletCoin) -> String {
        guard let exported = try? WalletExportedSecret.privateKey(privateKey, coin: coin) else { return "" }
        defer { exported.invalidate() }
        var text = ""
        exported.withText { text = $0 }
        return text
    }
}
