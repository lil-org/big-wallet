import Foundation
import LocalAuthentication
import WalletDomain
@testable import WalletAuthority

final class HarnessVaultKeyStore: SafariApprovalKeyStoring {
    private let file: URL
    private let lock: AuthorityFileLock

    init(root: URL) {
        file = root.appendingPathComponent("vault-keys.plist")
        lock = AuthorityFileLock(fileURL: root.appendingPathComponent("vault-keys.lock"))
    }

    func store(_ key: Data, identity: SafariApprovalKeyIdentity) throws {
        try withLock {
            var keys = try read()
            keys[try identity.keychainAccount()] = key
            try PropertyListEncoder().encode(keys).write(to: file, options: .atomic)
        }
    }

    func load(identity: SafariApprovalKeyIdentity, context: LAContext) throws -> Data {
        try withLock {
            guard let key = try read()[identity.keychainAccount()] else { throw SafariApprovalVault.Error.invalidKey }
            return key
        }
    }

    func availability(identities: [SafariApprovalKeyIdentity]) -> [SafariApprovalKeyIdentity: SafariApprovalKeyAvailability] {
        do {
            return try withLock {
                let keys = try read()
                return try Dictionary(uniqueKeysWithValues: identities.map { identity in
                    (identity, keys[try identity.keychainAccount()] == nil ? .missing : .authenticationRequired)
                })
            }
        } catch { return Dictionary(uniqueKeysWithValues: identities.map { ($0, .unavailable(-1)) }) }
    }

    func removeAll() throws {
        try withLock { try PropertyListEncoder().encode([String: Data]()).write(to: file, options: .atomic) }
    }

    private func read() throws -> [String: Data] {
        do { return try PropertyListDecoder().decode([String: Data].self, from: Data(contentsOf: file)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [:] }
    }

    private func withLock<Value>(_ operation: () throws -> Value) throws -> Value {
        try lock.acquire(timeoutNanoseconds: 1_000_000_000, pollNanoseconds: 1_000_000)
        defer { lock.release() }
        return try operation()
    }
}

struct HarnessVaultPublication: Codable {
    let generation: UUID
    let envelopeDigest: Data
    let sourceMAC: Data

    init(_ publication: SafariApprovalVault.Publication) {
        generation = publication.generation
        envelopeDigest = publication.envelopeDigest
        sourceMAC = publication.sourceMAC
    }
}
