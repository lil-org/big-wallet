// ∅ 2026 lil org

import CryptoKit
import Darwin
import Foundation
import Synchronization
import LocalAuthentication
import OSLog
import Security
#if os(iOS) || os(visionOS)
import UIKit
#endif

final class SafariApprovalReconciliationActivity: Sendable {
    private struct Resources: Sendable {
        let lease: SafariApprovalVault.CoordinationLease?
        let end: (@Sendable () -> Void)?

        func finish() {
            lease?.release()
            end?()
        }
    }

    private struct State {
        var active = true
        var operations = 0
        var lease: SafariApprovalVault.CoordinationLease?
        var end: (@Sendable () -> Void)?

        mutating func retireIfIdle() -> Resources? {
            guard !active, operations == 0 else { return nil }
            let resources = Resources(lease: lease, end: end)
            lease = nil
            end = nil
            return resources
        }
    }

    private let state = Mutex(State())

    init?(begin: (@escaping @Sendable () -> Void) -> (@Sendable () -> Void)?) {
        guard let end = begin({ [weak self] in self?.finish() }) else {
            finish()
            return nil
        }
        let installed = state.withLock { state in
            guard state.active else { return false }
            state.end = end
            return true
        }
        guard installed else {
            end()
            return nil
        }
    }

    func withActive<Result>(_ operation: () throws -> Result) throws -> Result {
        let admitted = state.withLock { state in
            guard state.active else { return false }
            state.operations += 1
            return true
        }
        guard admitted else { throw CancellationError() }
        defer {
            let resources = state.withLock { state in
                state.operations -= 1
                return state.retireIfIdle()
            }
            resources?.finish()
        }
        return try operation()
    }

    func checkCancellation() throws {
        guard state.withLock({ $0.active }) else { throw CancellationError() }
    }

    func acquireLease(from vault: SafariApprovalVault) throws -> SafariApprovalVault.CoordinationLease? {
        try withActive {
            let acquired = try vault.tryAcquireCoordinationLease()
            state.withLock { $0.lease = acquired }
            return acquired
        }
    }

    func finish() {
        let resources = state.withLock { state in
            state.active = false
            return state.retireIfIdle()
        }
        resources?.finish()
    }

    deinit { finish() }
}

struct SafariApprovalWalletRecord: Codable, Equatable, Sendable {
    let walletID: String
    var storedKeyJSON: Data
}

struct SafariApprovalSourceSnapshot: Sendable {
    let catalog: WalletAccountCatalog
    var password: Data
    var wallets: [SafariApprovalWalletRecord]

    mutating func resetSecrets() {
        password.resetBytes(in: 0..<password.count)
        password.removeAll(keepingCapacity: false)
        for index in wallets.indices {
            wallets[index].storedKeyJSON.resetBytes(
                in: 0..<wallets[index].storedKeyJSON.count
            )
        }
        wallets.removeAll(keepingCapacity: false)
    }
}

enum SafariApprovalKeyAvailability: Equatable, Sendable {
    case present
    case authenticationRequired
    case missing
    case unavailable(OSStatus)

    var permitsPublishedEnvelope: Bool {
        switch self {
        case .present, .authenticationRequired:
            return true
        case .missing, .unavailable:
            return false
        }
    }
}

private enum SafariApprovalDiagnostics {
    private static let logger = Logger(
        subsystem: "org.lil.wallet",
        category: "SafariApprovalVault"
    )

    static func record(_ operation: String, error: Swift.Error) {
        if let failure = error as? SafariApprovalVault.Error,
           case .keychainFailure(let status) = failure {
            logger.error("\(operation, privacy: .public) failed: OSStatus=\(status)")
        } else {
            let error = error as NSError
            logger.error("\(operation, privacy: .public) failed: domain=\(error.domain, privacy: .public) code=\(error.code)")
        }
    }
}

struct SafariApprovalKeyIdentity: Hashable, Sendable {
    let generation: UUID
    let account: WalletAccountDescriptor

    func keychainAccount() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(account))
        let accountDigest = digest.map { String(format: "%02x", $0) }.joined()
        return generation.uuidString.lowercased() + ":" + accountDigest
    }
}

final class SafariApprovalAuthenticationContext: Sendable {
    // LAContext.invalidate cancels pending authentication; it must bypass a blocked protected-key read.
    nonisolated(unsafe) private let context: LAContext
    private let access = Mutex(())
    private let invalidated = Mutex(false)
    let identity: ObjectIdentifier

    init() {
        let context = LAContext()
        self.context = context
        identity = ObjectIdentifier(context)
    }

    var isInvalidated: Bool { invalidated.withLock { $0 } }

    func read<Value: Sendable>(_ operation: @Sendable (LAContext) throws -> Value) rethrows -> Value {
        try access.withLock { _ in try operation(context) }
    }

    func invalidate() {
        let shouldInvalidate = invalidated.withLock { invalidated in
            guard !invalidated else { return false }
            invalidated = true
            return true
        }
        if shouldInvalidate { context.invalidate() }
    }

    func evaluate(policy: LAPolicy, reason: String) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                read { context in
                    context.evaluatePolicy(policy, localizedReason: reason) { succeeded, _ in
                        continuation.resume(returning: succeeded)
                    }
                }
            }
        } onCancel: {
            self.invalidate()
        }
    }
}

protocol SafariApprovalKeyStoring: AnyObject, Sendable {
    func store(_ key: Data, identity: SafariApprovalKeyIdentity) throws
    func load(identity: SafariApprovalKeyIdentity, context: LAContext) throws -> Data
    func availability(
        identities: [SafariApprovalKeyIdentity]
    ) -> [SafariApprovalKeyIdentity: SafariApprovalKeyAvailability]
    func removeAll() throws
}

protocol SafariApprovalIntegrityKeyStoring: AnyObject, Sendable {
    func loadOrCreate() throws -> Data
}

final class SafariApprovalIntegrityKeychainStore:
    SafariApprovalIntegrityKeyStoring {

    private enum LoadResult {
        case success(Data)
        case failure(OSStatus)
    }

    static let accessGroup = "8DXC3N7E7P.org.lil.keychain"
    static let service = "org.lil.wallet.safari-approval-integrity.v1"
    static let account = "source-snapshot-hmac"
    static var accessibility: CFString { kSecAttrAccessibleWhenUnlockedThisDeviceOnly }

    typealias Add = @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    typealias CopyMatching = @Sendable (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    typealias RandomKey = @Sendable () throws -> Data

    private let add: Add
    private let copyMatching: CopyMatching
    private let randomKey: RandomKey

    init(
        add: @escaping Add = { SecItemAdd($0, $1) },
        copyMatching: @escaping CopyMatching = { SecItemCopyMatching($0, $1) },
        randomKey: @escaping RandomKey = { try SafariApprovalVault.makeRandomKey() }
    ) {
        self.add = add
        self.copyMatching = copyMatching
        self.randomKey = randomKey
    }

    func loadOrCreate() throws -> Data {
        switch load() {
        case .success(let key):
            guard key.count == 32 else {
                throw SafariApprovalVault.Error.invalidKey
            }
            return key
        case .failure(let status) where status == errSecItemNotFound:
            break
        case .failure(let status):
            throw SafariApprovalVault.Error.keychainFailure(status)
        }

        var key = try randomKey()
        guard key.count == 32 else {
            key.resetBytes(in: 0..<key.count)
            throw SafariApprovalVault.Error.invalidKey
        }
        let query = Self.storeQuery(key)
        let status = add(query as CFDictionary, nil)
        if status == errSecSuccess {
            return key
        }
        key.resetBytes(in: 0..<key.count)
        if status == errSecDuplicateItem,
           case .success(let existing) = load(),
           existing.count == 32 {
            return existing
        }
        throw SafariApprovalVault.Error.keychainFailure(status)
    }

    static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static var loadQuery: [String: Any] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    static func storeQuery(_ key: Data) -> [String: Any] {
        var query = baseQuery
        query[kSecValueData as String] = key
        query[kSecAttrAccessible as String] = accessibility
        return query
    }

    private func load() -> LoadResult {
        var item: CFTypeRef?
        let status = copyMatching(Self.loadQuery as CFDictionary, &item)
        guard status == errSecSuccess else { return .failure(status) }
        guard let key = item as? Data else { return .failure(errSecDecode) }
        return .success(key)
    }
}

final class SafariApprovalKeychainStore: SafariApprovalKeyStoring {

    static let accessGroup = "8DXC3N7E7P.org.lil.wallet.safari-approval"
    static let service = "org.lil.wallet.safari-approval-key.v1"
    static var accessibility: CFString { kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly }
    static let accessControlFlags = SecAccessControlCreateFlags.userPresence

    typealias Add = @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    typealias CopyMatching = @Sendable (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    typealias Delete = @Sendable (CFDictionary) -> OSStatus

    private let add: Add
    private let copyMatching: CopyMatching
    private let delete: Delete

    init(
        add: @escaping Add = { SecItemAdd($0, $1) },
        copyMatching: @escaping CopyMatching = { SecItemCopyMatching($0, $1) },
        delete: @escaping Delete = { SecItemDelete($0) }
    ) {
        self.add = add
        self.copyMatching = copyMatching
        self.delete = delete
    }

    func store(_ key: Data, identity: SafariApprovalKeyIdentity) throws {
        guard key.count == 32 else { throw SafariApprovalVault.Error.invalidKey }
        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            Self.accessibility,
            Self.accessControlFlags,
            &accessControlError
        ) else {
            throw SafariApprovalVault.Error.keychainFailure(errSecParam)
        }

        var addQuery = try Self.baseQuery(identity: identity)
        addQuery[kSecValueData as String] = key
        addQuery[kSecAttrAccessControl as String] = accessControl
        let status = add(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SafariApprovalVault.Error.keychainFailure(status)
        }
    }

    func load(identity: SafariApprovalKeyIdentity, context: LAContext) throws -> Data {
        let query = try Self.loadQuery(identity: identity, context: context)
        var item: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let key = item as? Data else {
            throw SafariApprovalVault.Error.keychainFailure(
                status == errSecSuccess ? errSecDecode : status
            )
        }
        return key
    }

    func availability(
        identities: [SafariApprovalKeyIdentity]
    ) -> [SafariApprovalKeyIdentity: SafariApprovalKeyAvailability] {
        guard !identities.isEmpty else { return [:] }
        let context = LAContext()
        context.interactionNotAllowed = true
        if identities.count == 1, let identity = identities.first {
            return [identity: availability(identity: identity, context: context)]
        }
        var selectors = [SafariApprovalKeyIdentity: String]()
        do {
            for identity in identities {
                selectors[identity] = try identity.keychainAccount()
            }
        } catch {
            return identities.reduce(into: [:]) {
                $0[$1] = .unavailable(errSecParam)
            }
        }
        let query = Self.inventoryQuery(context: context)
        var item: CFTypeRef?
        switch copyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let attributes = item as? [[String: Any]] else {
                return selectors.mapValues { _ in .unavailable(errSecDecode) }
            }
            let accounts = attributes.compactMap { $0[kSecAttrAccount as String] as? String }
            guard accounts.count == attributes.count else {
                return selectors.mapValues { _ in .unavailable(errSecDecode) }
            }
            let available = Set(accounts)
            return selectors.mapValues { available.contains($0) ? .present : .missing }
        case errSecInteractionNotAllowed:
            return identities.reduce(into: [:]) { result, identity in
                result[identity] = availability(identity: identity, context: context)
            }
        case errSecItemNotFound:
            return selectors.mapValues { _ in .missing }
        case let status:
            return selectors.mapValues { _ in .unavailable(status) }
        }
    }

    private func availability(
        identity: SafariApprovalKeyIdentity,
        context: LAContext
    ) -> SafariApprovalKeyAvailability {
        guard let query = try? Self.availabilityQuery(identity: identity, context: context)
        else { return .unavailable(errSecParam) }
        var item: CFTypeRef?
        switch copyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            return .present
        case errSecInteractionNotAllowed:
            return .authenticationRequired
        case errSecItemNotFound:
            return .missing
        case let status:
            return .unavailable(status)
        }
    }

    func removeAll() throws {
        let status = delete(Self.commonQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SafariApprovalVault.Error.keychainFailure(status)
        }
    }

    static var commonQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func baseQuery(identity: SafariApprovalKeyIdentity) throws -> [String: Any] {
        var query = commonQuery
        query[kSecAttrAccount as String] = try identity.keychainAccount()
        return query
    }

    static func loadQuery(
        identity: SafariApprovalKeyIdentity,
        context: LAContext
    ) throws -> [String: Any] {
        var query = try baseQuery(identity: identity)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    static func availabilityQuery(
        identity: SafariApprovalKeyIdentity,
        context: LAContext
    ) throws -> [String: Any] {
        var query = try baseQuery(identity: identity)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    static func inventoryQuery(context: LAContext) -> [String: Any] {
        var query = commonQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

}

final class SafariApprovalVault: Sendable {

    final class CoordinationLease: Sendable {
        fileprivate let owner: ObjectIdentifier
        private let lock: CrossProcessFileLock
        private let active = Mutex(true)

        fileprivate init(
            owner: ObjectIdentifier,
            lock: CrossProcessFileLock
        ) {
            self.owner = owner
            self.lock = lock
        }

        fileprivate var isActive: Bool {
            active.withLock { $0 }
        }

        func release() {
            let shouldRelease = active.withLock { active in
                guard active else { return false }
                active = false
                return true
            }
            if shouldRelease { lock.release() }
        }

        deinit {
            release()
        }
    }

    private final class SigningSource: WalletSigningSource {
        private struct State {
            weak var vault: SafariApprovalVault?
        }

        let approvedAccount: WalletAccountDescriptor
        let requiresCommitLease = true
        private let snapshotData: Data
        private let keyIdentity: SafariApprovalKeyIdentity
        private let signer: UnlockedAccountSigner
        private let state: Mutex<State>

        init(
            vault: SafariApprovalVault,
            snapshotData: Data,
            keyIdentity: SafariApprovalKeyIdentity,
            signer: UnlockedAccountSigner
        ) {
            approvedAccount = keyIdentity.account
            self.snapshotData = snapshotData
            self.keyIdentity = keyIdentity
            self.signer = signer
            state = Mutex(State(vault: vault))
        }

        func isCurrent() -> Bool {
            guard let vault = state.withLock({ $0.vault }),
                  vault.isCurrent(snapshotData, keyIdentity: keyIdentity) else { return false }
            return state.withLock { $0.vault === vault }
        }

        @MainActor
        func sign(_ operation: ApprovedWalletSigningOperation) async -> Result<WalletSigningOutput, WalletSigningFailure> {
            guard state.withLock({ $0.vault != nil }) else {
                return .failure(.authorizationUnavailable)
            }
            return await signer.sign(operation, validating: self)
        }

        func retireSigningMaterial() {
            signer.invalidate()
        }

        @MainActor
        func acquireCommitLease() async -> WalletExecutionLease? {
            guard !Task.isCancelled, let vault = state.withLock({ $0.vault }) else { return nil }
            let lease = await vault.executionLease(ifCurrent: snapshotData, keyIdentity: keyIdentity)
            guard !Task.isCancelled, state.withLock({ $0.vault === vault }) else {
                lease?.release()
                return nil
            }
            return lease
        }

        func invalidate() {
            state.withLock { $0.vault = nil }
            signer.invalidate()
        }

        deinit {
            invalidate()
        }
    }

    struct Publication: Equatable {
        let generation: UUID
        let envelopeDigest: Data
        let sourceMAC: Data
    }

    enum PublicationStatus: Equatable {
        case current
        case stale
        case unavailable(OSStatus)
    }

    enum Error: Swift.Error, Equatable {
        case unavailable
        case invalidEnvelope
        case invalidCatalog
        case invalidKey
        case payloadTooLarge
        case keychainFailure(OSStatus)
        case authenticationFailed
    }

    private struct Header: Codable, Equatable {
        let version: Int
        let generation: UUID
    }

    private struct Envelope: Codable, Equatable {
        let version: Int
        let generation: UUID
        let header: Data
        let catalog: Data
        let accounts: [EncryptedAccount]
    }

    private struct EncryptedAccount: Codable, Equatable {
        let account: WalletAccountDescriptor
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    private struct AccountBinding: Encodable {
        let domain = "org.lil.wallet.safari-approval.account.v1"
        let header: Data
        let catalogDigest: Data
        let account: WalletAccountDescriptor
    }

    private struct EnvelopeRecord {
        let envelope: Envelope
        let data: Data
        let catalog: ValidatedWalletAccountCatalog
        let catalogDigest: Data

        var keyIdentities: [SafariApprovalKeyIdentity] {
            catalog.catalog.accounts.map {
                SafariApprovalKeyIdentity(generation: envelope.generation, account: $0)
            }
        }
    }

    private struct AccountKey {
        let identity: SafariApprovalKeyIdentity
        var data: Data

        mutating func resetSecret() {
            data.resetBytes(in: 0..<data.count)
            data.removeAll(keepingCapacity: false)
        }
    }

    private struct SourceFingerprint: Encodable {
        let catalog: Data
        var password: Data
        var wallets: [SafariApprovalWalletRecord]

        mutating func resetSecrets() {
            password.resetBytes(in: 0..<password.count)
            password.removeAll(keepingCapacity: false)
            for index in wallets.indices {
                wallets[index].storedKeyJSON.resetBytes(
                    in: 0..<wallets[index].storedKeyJSON.count
                )
            }
            wallets.removeAll(keepingCapacity: false)
        }
    }

    static let shared = SafariApprovalVault()
    static let envelopeVersion = 1
    static let maximumEnvelopeBytes = 8 * 1_024 * 1_024
    static let coordinationLockTimeoutNanoseconds: UInt64 = 5_000_000_000

    typealias Authentication = @Sendable (SafariApprovalAuthenticationContext, LAPolicy, String) async -> Bool
    typealias CanEvaluateAuthentication = @Sendable (LAContext, LAPolicy) -> Bool
    typealias RandomKey = @Sendable () throws -> Data
    typealias AtomicWrite = @Sendable (Data, URL) throws -> Void

    private let fileURL: URL?
    private let keyStore: SafariApprovalKeyStoring
    private let authentication: Authentication
    private let canEvaluateAuthentication: CanEvaluateAuthentication
    private let randomKey: RandomKey
    private let atomicWrite: AtomicWrite
    private let coordinationLockURL: URL?
    private let lock = Mutex(())

    init(
        fileURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedDefaults.suiteName
        )?.appendingPathComponent(
            "SafariApprovalVault.v1",
            isDirectory: false
        ),
        keyStore: SafariApprovalKeyStoring = SafariApprovalKeychainStore(),
        canEvaluateAuthentication: @escaping CanEvaluateAuthentication = {
            $0.canEvaluatePolicy($1, error: nil)
        },
        authentication: @escaping Authentication = {
            await $0.evaluate(policy: $1, reason: $2)
        },
        randomKey: @escaping RandomKey = { try SafariApprovalVault.makeRandomKey() },
        atomicWrite: @escaping AtomicWrite = {
            try $0.write(to: $1, options: .atomic)
        }
    ) {
        self.fileURL = fileURL
        self.keyStore = keyStore
        self.canEvaluateAuthentication = canEvaluateAuthentication
        self.authentication = authentication
        self.randomKey = randomKey
        self.atomicWrite = atomicWrite
        coordinationLockURL = fileURL?.appendingPathExtension(
            "coordination-lock"
        )
    }

    @discardableResult
    func publish(
        source: SafariApprovalSourceSnapshot,
        integrityKey: Data,
        coordinationLease: CoordinationLease? = nil,
        activity: SafariApprovalReconciliationActivity? = nil
    ) throws -> Publication {
        try withCoordination(coordinationLease) {
            try publishCoordinated(
                source: source,
                integrityKey: integrityKey,
                activity: activity
            )
        }
    }

    private func publishCoordinated(
        source: SafariApprovalSourceSnapshot,
        integrityKey: Data,
        activity: SafariApprovalReconciliationActivity?
    ) throws -> Publication {
        try activity?.checkCancellation()
        guard source.catalog.isValid else { throw Error.invalidCatalog }
        guard integrityKey.count == 32 else { throw Error.invalidKey }
        let generation = UUID()
        let catalogData = try source.catalog.canonicalData()
        let header = Header(
            version: Self.envelopeVersion,
            generation: generation
        )
        let headerData = try canonicalEncoder().encode(header)
        let catalogDigest = Self.digest(catalogData)
        let sourceMAC = try sourceAuthenticationCode(
            source: source,
            catalogData: catalogData,
            integrityKey: integrityKey
        )
        guard !source.password.isEmpty,
              let wallets = WalletSnapshotValidation.wallets(
                  catalog: source.catalog,
                  walletRecords: source.wallets.map {
                      (id: $0.walletID, data: $0.storedKeyJSON)
                  }
              ) else { throw Error.invalidCatalog }

        var accounts = [EncryptedAccount]()
        accounts.reserveCapacity(source.catalog.accounts.count)
        var keys = [AccountKey]()
        keys.reserveCapacity(source.catalog.accounts.count)
        defer {
            for index in keys.indices { keys[index].resetSecret() }
        }
        var nonces = Set<Data>()
        for wallet in wallets {
            guard try WalletSnapshotValidation.visitOwnedAccountKeys(
                wallet,
                password: source.password,
                checkCancellation: { try activity?.checkCancellation() },
                visit: { account, privateKey in
                    try activity?.checkCancellation()
                    let descriptor = WalletAccountDescriptor(walletID: wallet.id, account: account)
                    var key = try self.randomKey()
                    defer { key.resetBytes(in: 0..<key.count) }
                    guard key.count == 32 else { throw Error.invalidKey }
                    try activity?.checkCancellation()
                    let aad = try self.authenticatedData(
                        header: headerData,
                        catalogDigest: catalogDigest,
                        account: descriptor
                    )
                    let sealed = try privateKey.withData {
                        try AES.GCM.seal($0, using: SymmetricKey(data: key), authenticating: aad)
                    }
                    let nonce = sealed.nonce.withUnsafeBytes { Data($0) }
                    guard nonces.insert(nonce).inserted else { throw Error.invalidEnvelope }
                    accounts.append(EncryptedAccount(
                        account: descriptor,
                        nonce: nonce,
                        ciphertext: sealed.ciphertext,
                        tag: sealed.tag
                    ))
                    keys.append(AccountKey(
                        identity: SafariApprovalKeyIdentity(generation: generation, account: descriptor),
                        data: key
                    ))
                }
            ) else { throw Error.invalidCatalog }
        }
        try activity?.checkCancellation()
        guard accounts.map(\.account) == source.catalog.accounts else {
            throw Error.invalidCatalog
        }
        let envelope = Envelope(
            version: header.version,
            generation: header.generation,
            header: headerData,
            catalog: catalogData,
            accounts: accounts
        )
        let envelopeData = try canonicalEncoder().encode(envelope)
        guard envelopeData.count <= Self.maximumEnvelopeBytes else {
            throw Error.payloadTooLarge
        }
        guard let fileURL else { throw Error.unavailable }

        return try commitPublication(
            envelope: envelope,
            envelopeData: envelopeData,
            keys: keys,
            sourceMAC: sourceMAC,
            fileURL: fileURL,
            activity: activity
        )
    }

    private func commitPublication(
        envelope: Envelope,
        envelopeData: Data,
        keys: [AccountKey],
        sourceMAC: Data,
        fileURL: URL,
        activity: SafariApprovalReconciliationActivity?
    ) throws -> Publication {
        func withActive(_ operation: () throws -> Void) throws {
            if let activity { try activity.withActive(operation) }
            else { try operation() }
        }
        let generation = envelope.generation
        return try withLock {
            try withActive { try writeTombstoneLocked() }
            var committed = false
            defer {
                if !committed {
                    try? withActive {
                        try? writeTombstoneLocked()
                        try? deleteAllKeysLocked()
                    }
                }
            }
            try withActive { try deleteAllKeysLocked() }
            for key in keys {
                try withActive {
                    do {
                        try keyStore.store(key.data, identity: key.identity)
                    } catch {
                        SafariApprovalDiagnostics.record("store approval key", error: error)
                        throw error
                    }
                }
            }
            try activity?.checkCancellation()
            let availability = publicationKeyAvailability(identities: keys.map(\.identity))
            try activity?.checkCancellation()
            switch availability {
            case .present, .authenticationRequired:
                break
            case .missing:
                throw Error.keychainFailure(errSecItemNotFound)
            case .unavailable(let status):
                throw Error.keychainFailure(status)
            }
            try withActive {
                do {
                    try atomicWrite(envelopeData, fileURL)
                } catch {
                    SafariApprovalDiagnostics.record("write envelope", error: error)
                    throw Error.unavailable
                }
                guard let record = loadEnvelopeRecordLocked(),
                      record.data == envelopeData,
                      record.envelope == envelope else {
                    SafariApprovalDiagnostics.record(
                        "verify envelope",
                        error: Error.invalidEnvelope
                    )
                    throw Error.unavailable
                }
                committed = true
            }
            return Publication(
                generation: generation,
                envelopeDigest: Self.digest(envelopeData),
                sourceMAC: sourceMAC
            )
        }
    }

    func reviewCatalog() -> WalletReviewCatalog? {
        guard let catalog = approvalCatalog(),
              catalog.knownAccounts.isEmpty || !catalog.orderedAccounts.isEmpty else { return nil }
        return catalog
    }

    func approvalCatalog() -> WalletReviewCatalog? {
        withLock {
            guard let record = loadEnvelopeRecordLocked() else { return nil }
            return approvalCatalog(in: record)
        }
    }

    private func reviewCatalog(in record: EnvelopeRecord) -> WalletReviewCatalog? {
        let catalog = approvalCatalog(in: record)
        return catalog.knownAccounts.isEmpty || !catalog.orderedAccounts.isEmpty ? catalog : nil
    }

    private func approvalCatalog(in record: EnvelopeRecord) -> WalletReviewCatalog {
        let identities = record.keyIdentities
        let availability = identities.isEmpty ? [:] : keyStore.availability(identities: identities)
        let accounts = identities.filter {
            availability[$0]?.permitsPublishedEnvelope == true
        }.map(\.account.specificAccount)
        return WalletReviewCatalog(
            identity: WalletCatalogIdentity(
                generation: record.envelope.generation,
                catalogData: record.catalog.data
            ),
            orderedAccounts: accounts,
            knownAccounts: Set(record.catalog.catalog.accounts)
        )
    }

    private func publicationKeyAvailability(
        identities: [SafariApprovalKeyIdentity]
    ) -> SafariApprovalKeyAvailability {
        guard !identities.isEmpty else { return .present }
        let availability = keyStore.availability(identities: identities)
        var missing = false
        var requiresAuthentication = false
        for identity in identities {
            switch availability[identity] ?? .unavailable(errSecDecode) {
            case .present:
                break
            case .authenticationRequired:
                requiresAuthentication = true
            case .missing:
                missing = true
            case .unavailable(let status):
                return .unavailable(status)
            }
        }
        if missing { return .missing }
        return requiresAuthentication ? .authenticationRequired : .present
    }

    func publicationStatus(
        source: SafariApprovalSourceSnapshot,
        expectedGeneration: UUID,
        expectedEnvelopeDigest: Data,
        expectedSourceMAC: Data,
        integrityKey: Data
    ) -> PublicationStatus {
        guard integrityKey.count == 32,
              source.catalog.isValid,
              let catalogData = try? source.catalog.canonicalData() else { return .stale }
        guard (try? sourceAuthenticationCode(
            source: source,
            catalogData: catalogData,
            integrityKey: integrityKey
        )) == expectedSourceMAC else {
            return .stale
        }
        return withLock {
            guard let record = loadEnvelopeRecordLocked() else { return .stale }
            let envelope = record.envelope
            guard envelope.generation == expectedGeneration,
                  envelope.catalog == catalogData,
                  Self.digest(record.data) == expectedEnvelopeDigest else {
                return .stale
            }
            switch publicationKeyAvailability(identities: record.keyIdentities) {
            case .present, .authenticationRequired:
                return .current
            case .missing:
                return .stale
            case .unavailable(let status):
                return .unavailable(status)
            }
        }
    }

    @concurrent
    func unlockResult(
        reason: String,
        authorization: WalletSigningAuthorization
    ) async -> WalletUnlockResult {
        let approvedAccount = authorization.approvedAccount
        guard !Task.isCancelled,
              Date() < authorization.signingDeadline,
              approvedAccount.isValid,
              let record = withLock({ loadEnvelopeRecordLocked() }),
              let encryptedAccount = record.envelope.accounts.first(where: {
                  $0.account == approvedAccount
              }) else {
            return .unavailable
        }
        let envelope = record.envelope
        let snapshotData = record.data
        let keyIdentity = SafariApprovalKeyIdentity(
            generation: envelope.generation,
            account: approvedAccount
        )
        guard keyStore.availability(identities: [keyIdentity])[keyIdentity]?
            .permitsPublishedEnvelope == true else { return .unavailable }

        let context = SafariApprovalAuthenticationContext()
        return await withTaskCancellationHandler {
            context.read { $0.localizedCancelTitle = Strings.cancel }
            guard context.read({ canEvaluateAuthentication($0, .deviceOwnerAuthentication) }) else {
                return .unavailable
            }
            guard await authentication(
                context,
                .deviceOwnerAuthentication,
                reason
            ) else { return .canceled }

            guard let unlocked = unlockAccount(
                encryptedAccount,
                in: record,
                context: context,
                authorization: authorization
            ) else { return .unavailable }
            let source = SigningSource(
                vault: self,
                snapshotData: snapshotData,
                keyIdentity: keyIdentity,
                signer: unlocked.signer
            )
            guard source.isCurrent(),
                  !Task.isCancelled,
                  Date() < authorization.signingDeadline else {
                source.invalidate()
                return .unavailable
            }
            let session = WalletSigningSession(
                source: source,
                authorization: authorization
            )
            return .unlocked(catalog: unlocked.catalog, session: session)
        } onCancel: {
            context.invalidate()
        }
    }

    private func unlockAccount(
        _ encryptedAccount: EncryptedAccount,
        in record: EnvelopeRecord,
        context: SafariApprovalAuthenticationContext,
        authorization: WalletSigningAuthorization
    ) -> (catalog: WalletReviewCatalog, signer: UnlockedAccountSigner)? {
        guard !Task.isCancelled,
              Date() < authorization.signingDeadline else { return nil }
        let envelope = record.envelope
        let approvedAccount = authorization.approvedAccount
        var key: Data
        do {
            let identity = SafariApprovalKeyIdentity(generation: envelope.generation, account: approvedAccount)
            key = try context.read { try keyStore.load(identity: identity, context: $0) }
        } catch {
            SafariApprovalDiagnostics.record("load approval key", error: error)
            return nil
        }
        defer { key.resetBytes(in: 0..<key.count) }
        guard key.count == 32,
              !Task.isCancelled,
              Date() < authorization.signingDeadline else { return nil }

        guard let sealed = try? AES.GCM.SealedBox(
                  nonce: AES.GCM.Nonce(data: encryptedAccount.nonce),
                  ciphertext: encryptedAccount.ciphertext,
                  tag: encryptedAccount.tag
              ),
              let aad = try? authenticatedData(
                  header: envelope.header,
                  catalogDigest: record.catalogDigest,
                  account: approvedAccount
              ) else { return nil }
        guard var decrypted = try? AES.GCM.open(
                  sealed,
                  using: SymmetricKey(data: key),
                  authenticating: aad
              ) else {
            return nil
        }
        defer { decrypted.resetBytes(in: 0..<decrypted.count) }
        guard decrypted.count == 32,
              !Task.isCancelled,
              Date() < authorization.signingDeadline,
              let privateKey = WalletPrivateKey(data: decrypted),
              let signer = UnlockedAccountSigner(
                  approvedAccount: approvedAccount,
                  privateKey: privateKey
              ) else { return nil }
        guard let catalog = reviewCatalog(in: record),
              catalog.specificAccount(descriptor: approvedAccount) != nil else {
            signer.invalidate()
            return nil
        }
        return (catalog, signer)
    }

    func clear(coordinationLease: CoordinationLease? = nil) throws {
        try withCoordination(coordinationLease) {
            try withLock {
                try writeTombstoneLocked()
                try deleteAllKeysLocked()
            }
        }
    }

    func markUnavailable(
        coordinationLease: CoordinationLease? = nil
    ) throws {
        try withCoordination(coordinationLease) {
            try withLock { try writeTombstoneLocked() }
        }
    }

    func deleteAllKeys(
        coordinationLease: CoordinationLease? = nil
    ) throws {
        try withCoordination(coordinationLease) {
            try withLock { try deleteAllKeysLocked() }
        }
    }

    private func deleteAllKeysLocked() throws {
        do {
            try keyStore.removeAll()
        } catch {
            SafariApprovalDiagnostics.record("delete approval keys", error: error)
            throw error
        }
    }

    func acquireCoordinationLease(
        timeoutNanoseconds: UInt64 =
            SafariApprovalVault.coordinationLockTimeoutNanoseconds
    ) throws -> CoordinationLease {
        let coordinationLock = CrossProcessFileLock(
            fileURL: coordinationLockURL
        )
        try coordinationLock.acquire(
            timeoutNanoseconds: timeoutNanoseconds,
            pollNanoseconds: 10_000_000
        )
        return CoordinationLease(
            owner: ObjectIdentifier(self),
            lock: coordinationLock
        )
    }

    func tryAcquireCoordinationLease() throws -> CoordinationLease? {
        let coordinationLock = CrossProcessFileLock(
            fileURL: coordinationLockURL
        )
        guard try coordinationLock.tryAcquire() else { return nil }
        return CoordinationLease(
            owner: ObjectIdentifier(self),
            lock: coordinationLock
        )
    }

    private func writeTombstoneLocked() throws {
        guard let fileURL else { throw Error.unavailable }
        do {
            try atomicWrite(Data(), fileURL)
        } catch {
            SafariApprovalDiagnostics.record("write tombstone", error: error)
            throw Error.unavailable
        }
        guard loadEnvelopeRecordLocked() == nil else { throw Error.unavailable }
    }

    private func loadEnvelopeRecordLocked() -> EnvelopeRecord? {
        guard let fileURL,
              let data = Self.readEnvelopeData(at: fileURL),
              !data.isEmpty,
              data.count <= Self.maximumEnvelopeBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == Self.envelopeVersion,
              let header = try? JSONDecoder().decode(
                  Header.self,
                  from: envelope.header
              ),
              header.version == envelope.version,
              header.generation == envelope.generation,
              (try? canonicalEncoder().encode(header)) == envelope.header,
              envelope.catalog.count <= Self.maximumEnvelopeBytes,
              let catalog = ValidatedWalletAccountCatalog(data: envelope.catalog),
              envelope.accounts.map(\.account) == catalog.catalog.accounts,
              envelope.accounts.allSatisfy({
                  $0.nonce.count == 12 && $0.ciphertext.count == 32 && $0.tag.count == 16
              }),
              Set(envelope.accounts.map(\.nonce)).count == envelope.accounts.count
        else { return nil }
        return EnvelopeRecord(
            envelope: envelope,
            data: data,
            catalog: catalog,
            catalogDigest: Self.digest(catalog.data)
        )
    }

    private static func readEnvelopeData(at fileURL: URL) -> Data? {
        let descriptor: Int32 = fileURL.withUnsafeFileSystemRepresentation {
            guard let path = $0 else { return -1 }
            return Darwin.open(
                path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        guard let initial = fileMetadata(descriptor),
              (initial.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              initial.st_size >= 0,
              initial.st_size <= off_t(maximumEnvelopeBytes) else {
            return nil
        }

        let expectedCount = Int(initial.st_size)
        var data = Data(count: expectedCount)
        let readAll = data.withUnsafeMutableBytes { bytes in
            guard expectedCount > 0 else { return true }
            guard let baseAddress = bytes.baseAddress else { return false }
            var offset = 0
            while offset < expectedCount {
                let count = retryingRead(
                    descriptor,
                    into: baseAddress.advanced(by: offset),
                    count: expectedCount - offset
                )
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard readAll else { return nil }

        var trailingByte: UInt8 = 0
        let trailingCount = withUnsafeMutableBytes(of: &trailingByte) { bytes in
            retryingRead(
                descriptor,
                into: bytes.baseAddress!,
                count: bytes.count
            )
        }
        guard trailingCount == 0,
              let final = fileMetadata(descriptor),
              sameSnapshot(initial, final),
              data.count <= maximumEnvelopeBytes else { return nil }
        return data
    }

    private static func fileMetadata(_ descriptor: Int32) -> stat? {
        var metadata = stat()
        var result: Int32
        repeat {
            result = Darwin.fstat(descriptor, &metadata)
        } while result == -1 && errno == EINTR
        return result == 0 ? metadata : nil
    }

    private static func retryingRead(
        _ descriptor: Int32,
        into buffer: UnsafeMutableRawPointer,
        count: Int
    ) -> Int {
        var result: Int
        repeat {
            result = Darwin.read(descriptor, buffer, count)
        } while result == -1 && errno == EINTR
        return result
    }

    private static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev &&
            lhs.st_ino == rhs.st_ino &&
            lhs.st_mode == rhs.st_mode &&
            lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private func isCurrent(
        _ snapshotData: Data,
        keyIdentity: SafariApprovalKeyIdentity
    ) -> Bool {
        withLock {
            fileURL.flatMap(Self.readEnvelopeData(at:)) == snapshotData &&
                keyStore.availability(identities: [keyIdentity])[keyIdentity]?
                    .permitsPublishedEnvelope == true
        }
    }

    @concurrent
    private func executionLease(
        ifCurrent snapshotData: Data,
        keyIdentity: SafariApprovalKeyIdentity
    ) async -> WalletExecutionLease? {
        let coordinationLock = CrossProcessFileLock(fileURL: coordinationLockURL)
        let deadline = ContinuousClock.now + .nanoseconds(
            Int64(Self.coordinationLockTimeoutNanoseconds)
        )
        do {
            while true {
                try Task.checkCancellation()
                if try coordinationLock.tryAcquire() { break }
                guard ContinuousClock.now < deadline else { return nil }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            return nil
        }
        guard isCurrent(snapshotData, keyIdentity: keyIdentity) else {
            coordinationLock.release()
            return nil
        }
        return WalletExecutionLease {
            coordinationLock.release()
        }
    }

    private func withCoordination<Result>(
        _ suppliedLease: CoordinationLease?,
        operation: () throws -> Result
    ) throws -> Result {
        if let suppliedLease {
            guard suppliedLease.owner == ObjectIdentifier(self),
                  suppliedLease.isActive else { throw Error.unavailable }
            return try operation()
        }
        let acquiredLease: CoordinationLease
        do {
            acquiredLease = try acquireCoordinationLease()
        } catch {
            throw Error.unavailable
        }
        defer { acquiredLease.release() }
        return try operation()
    }

    private func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        try lock.withLock { _ in try operation() }
    }

    private func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func authenticatedData(
        header: Data,
        catalogDigest: Data,
        account: WalletAccountDescriptor
    ) throws -> Data {
        try canonicalEncoder().encode(AccountBinding(
            header: header,
            catalogDigest: catalogDigest,
            account: account
        ))
    }

    private func sourceAuthenticationCode(
        source: SafariApprovalSourceSnapshot,
        catalogData: Data,
        integrityKey: Data
    ) throws -> Data {
        var fingerprint = SourceFingerprint(
            catalog: catalogData,
            password: source.password,
            wallets: source.wallets
        )
        defer { fingerprint.resetSecrets() }
        var data = try canonicalEncoder().encode(fingerprint)
        defer { data.resetBytes(in: 0..<data.count) }
        guard data.count <= Self.maximumEnvelopeBytes else { throw Error.payloadTooLarge }
        return Self.authenticationCode(for: data, key: integrityKey)
    }

    fileprivate static func makeRandomKey() throws -> Data {
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(
                kSecRandomDefault,
                bytes.count,
                bytes.baseAddress!
            )
        }
        guard status == errSecSuccess else {
            key.resetBytes(in: 0..<key.count)
            throw Error.invalidKey
        }
        return key
    }

    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func authenticationCode(for data: Data, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: data,
            using: SymmetricKey(data: key)
        ))
    }
}

#if os(iOS) || os(visionOS)
private final class VaultProtectedDataObservation: Sendable {
    private let center: NotificationCenter
    private let token: Mutex<NSObjectProtocol?>

    init(center: NotificationCenter, name: Notification.Name, action: @escaping @Sendable () -> Void) {
        self.center = center
        token = Mutex(center.addObserver(forName: name, object: nil, queue: nil) { _ in action() })
    }

    deinit {
        token.withLock { token in
            if let token { center.removeObserver(token) }
            token = nil
        }
    }
}
#endif

#if os(iOS) || os(visionOS)
actor SafariApprovalVaultHost {
    private struct PublicationMetadata: Codable, Sendable {
        let generation: UUID
        let envelopeDigest: Data
        let sourceMAC: Data
    }

    typealias SynchronizeDefaults = @Sendable (UserDefaults) -> Bool
    typealias BackgroundTask = @Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void)?

    private final class PublicationStorage: Sendable {
        // UserDefaults operations are thread-safe; the coordination lease orders publication transactions.
        nonisolated(unsafe) private let defaults: UserDefaults
        private let synchronizeDefaults: SynchronizeDefaults

        init(defaults: UserDefaults, synchronize: @escaping SynchronizeDefaults) {
            self.defaults = defaults
            synchronizeDefaults = synchronize
        }

        func data() -> Data? { defaults.data(forKey: publicationMetadataKey) }
        func set(_ data: Data) { defaults.set(data, forKey: publicationMetadataKey) }
        func remove() { defaults.removeObject(forKey: publicationMetadataKey) }
        func synchronize() -> Bool { synchronizeDefaults(defaults) }
    }

    static let shared = SafariApprovalVaultHost()

    private let vault: SafariApprovalVault
    private let metadata: PublicationStorage
    private let integrityKeyStore: SafariApprovalIntegrityKeyStoring
    private let sourceSnapshot: @Sendable () async throws -> SafariApprovalSourceSnapshot?
    private let notificationCenter: NotificationCenter
    private let waitForReconciliationRetry: @Sendable () async throws -> Void
    private let protectedDataObservation = Mutex<VaultProtectedDataObservation?>(nil)
    private var backgroundTask: BackgroundTask?
    private var reconciliationTask: Task<Void, Never>?
    private var reconciliationRetry: Task<Void, Never>?
    private var isPublishing = false
    private var reconciliationRequested = false
    private let waitToReconcile: @Sendable () async -> Void

    init(
        vault: SafariApprovalVault = .shared,
        defaults: UserDefaults = .standard,
        integrityKeyStore: SafariApprovalIntegrityKeyStoring = SafariApprovalIntegrityKeychainStore(),
        synchronizeDefaults: @escaping SynchronizeDefaults = { $0.synchronize() },
        notificationCenter: NotificationCenter = .default,
        waitToReconcile: @escaping @Sendable () async -> Void = {},
        waitForReconciliationRetry: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(100))
        },
        sourceSnapshot: @escaping @Sendable () async throws -> SafariApprovalSourceSnapshot? = {
            try await WalletsManager.shared.safariApprovalSourceSnapshot()
        }
    ) {
        self.vault = vault
        metadata = PublicationStorage(defaults: defaults, synchronize: synchronizeDefaults)
        self.integrityKeyStore = integrityKeyStore
        self.notificationCenter = notificationCenter
        self.waitToReconcile = waitToReconcile
        self.waitForReconciliationRetry = waitForReconciliationRetry
        self.sourceSnapshot = sourceSnapshot
    }

    deinit { reconciliationRetry?.cancel() }

    @available(iOSApplicationExtension, unavailable)
    @available(visionOSApplicationExtension, unavailable)
    nonisolated static func backgroundTask(using application: UIApplication) -> BackgroundTask {
        { expiration in
            let identifier = application.beginBackgroundTask(
                withName: "Publish Safari approval vault",
                expirationHandler: expiration
            )
            guard identifier != .invalid else { return nil }
            return { application.endBackgroundTask(identifier) }
        }
    }

    func start(backgroundTask: @escaping BackgroundTask) async {
        guard self.backgroundTask == nil else { return }
        self.backgroundTask = backgroundTask
        let observer = VaultProtectedDataObservation(
            center: notificationCenter,
            name: UIApplication.protectedDataDidBecomeAvailableNotification
        ) { [weak self] in
            Task { await self?.reconcile() }
        }
        protectedDataObservation.withLock { $0 = observer }
        reconcile()
    }

    func reconcile() {
        reconciliationRequested = true
        guard reconciliationTask == nil else { return }
        reconciliationTask = Task { [weak self] in
            guard let self else { return }
            await self.runReconciliation()
        }
    }

    func waitForReconciliation() async {
        while let reconciliationTask { await reconciliationTask.value }
    }

    private func runReconciliation() async {
        defer { reconciliationTask = nil }
        while reconciliationRequested {
            await waitToReconcile()
            reconciliationRequested = false
            await reconcileIfAvailable()
        }
    }

    @concurrent
    private nonisolated func loadSourceSnapshot() async throws -> SafariApprovalSourceSnapshot? {
        try await sourceSnapshot()
    }

    private func reconcileIfAvailable() async {
        guard let begin = backgroundTask,
              let activity = SafariApprovalReconciliationActivity(begin: begin) else { return }
        defer { activity.finish() }
        do {
            guard let coordinationLease = try activity.acquireLease(from: vault) else {
                try activity.withActive { scheduleRetry() }
                return
            }
            cancelReconciliationRetry()
            isPublishing = true
            defer { isPublishing = false }
            await reconcilePublishedSource(coordinationLease: coordinationLease, activity: activity)
        } catch is CancellationError {
            return
        } catch {
            cancelReconciliationRetry()
            SafariApprovalDiagnostics.record("acquire coordination lock", error: error)
        }
    }

    private func scheduleRetry() {
        guard reconciliationRetry == nil else { return }
        let waitForReconciliationRetry = waitForReconciliationRetry
        reconciliationRetry = Task { [weak self] in
            do { try await waitForReconciliationRetry() }
            catch { return }
            await self?.retryReconciliation()
        }
    }

    private func retryReconciliation() {
        guard !Task.isCancelled else { return }
        reconciliationRetry = nil
        reconcile()
    }

    private func cancelReconciliationRetry() {
        reconciliationRetry?.cancel()
        reconciliationRetry = nil
    }

    func performSourceMutation<Preparation: Sendable, Result: Sendable>(
        preparing prepare: @escaping @Sendable () async throws -> Preparation,
        _ operation: @escaping @Sendable (Preparation) async throws -> Result
    ) async throws -> Result {
        try await performSourceMutation { willMutateSource in
            let prepared = try await prepare()
            try Task.checkCancellation()
            try willMutateSource()
            try Task.checkCancellation()
            return try await operation(prepared)
        }
    }

    func performSourceMutation<Result: Sendable>(
        _ operation: @Sendable (_ willMutateSource: @Sendable () throws -> Void) async throws -> Result
    ) async throws -> Result {
        var remainingExecutionWait = Duration.nanoseconds(Int64(SafariApprovalVault.coordinationLockTimeoutNanoseconds))
        var waitStarted: ContinuousClock.Instant?
        let lease: SafariApprovalVault.CoordinationLease
        while true {
            try Task.checkCancellation()
            if let waitStarted { remainingExecutionWait -= waitStarted.duration(to: .now) }
            waitStarted = nil
            if !isPublishing {
                do {
                    if let acquired = try vault.tryAcquireCoordinationLease() {
                        lease = acquired
                        break
                    }
                } catch {
                    throw SafariApprovalVault.Error.unavailable
                }
                guard remainingExecutionWait > .zero else { throw SafariApprovalVault.Error.unavailable }
                waitStarted = .now
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let mutation = Mutex((attempted: false, invalidated: false))
        defer {
            lease.release()
            if mutation.withLock({ $0.attempted }) {
                cancelReconciliationRetry()
                reconcile()
            }
        }
        let vault = vault
        let metadata = metadata
        return try await operation {
            try mutation.withLock { mutation in
                guard !mutation.invalidated else { return }
                mutation.attempted = true
                do { try vault.clear(coordinationLease: lease) }
                catch { throw SafariApprovalVault.Error.unavailable }
                metadata.remove()
                if !metadata.synchronize() {
                    SafariApprovalDiagnostics.record("invalidate publication metadata", error: SafariApprovalVault.Error.unavailable)
                }
                mutation.invalidated = true
            }
        }
    }

    private func reconcilePublishedSource(
        coordinationLease: SafariApprovalVault.CoordinationLease,
        activity: SafariApprovalReconciliationActivity? = nil
    ) async {
        var source: SafariApprovalSourceSnapshot
        do {
            try activity?.checkCancellation()
            guard let loaded = try await loadSourceSnapshot()
            else {
                clearVaultLocked(
                    coordinationLease: coordinationLease,
                    activity: activity
                )
                return
            }
            source = loaded
        } catch is CancellationError {
            return
        } catch Keychain.KeychainError.failedToRead(let status)
            where status == errSecInteractionNotAllowed {
            return
        } catch {
            SafariApprovalDiagnostics.record("load source snapshot", error: error)
            clearVaultLocked(
                coordinationLease: coordinationLease,
                activity: activity
            )
            return
        }
        defer { source.resetSecrets() }

        var integrityKey: Data
        do {
            if let activity {
                integrityKey = try activity.withActive { try integrityKeyStore.loadOrCreate() }
            } else {
                integrityKey = try integrityKeyStore.loadOrCreate()
            }
        } catch is CancellationError {
            return
        } catch SafariApprovalVault.Error.keychainFailure(let status)
            where status == errSecInteractionNotAllowed {
            return
        } catch {
            SafariApprovalDiagnostics.record("load integrity key", error: error)
            clearVaultLocked(
                coordinationLease: coordinationLease,
                activity: activity
            )
            return
        }
        defer { integrityKey.resetBytes(in: 0..<integrityKey.count) }
        guard integrityKey.count == 32 else {
            SafariApprovalDiagnostics.record(
                "validate integrity key",
                error: SafariApprovalVault.Error.invalidKey
            )
            clearVaultLocked(
                coordinationLease: coordinationLease,
                activity: activity
            )
            return
        }

        if let metadata = publicationMetadata() {
            switch vault.publicationStatus(
                source: source,
                expectedGeneration: metadata.generation,
                expectedEnvelopeDigest: metadata.envelopeDigest,
                expectedSourceMAC: metadata.sourceMAC,
                integrityKey: integrityKey
            ) {
            case .current:
                persistPublicationMetadata(metadata, activity: activity)
                return
            case .stale:
                break
            case .unavailable(let status):
                SafariApprovalDiagnostics.record(
                    "verify publication key",
                    error: SafariApprovalVault.Error.keychainFailure(status)
                )
                return
            }
        }

        do {
            let publication = try vault.publish(
                source: source,
                integrityKey: integrityKey,
                coordinationLease: coordinationLease,
                activity: activity
            )
            persistPublicationMetadata(PublicationMetadata(
                generation: publication.generation,
                envelopeDigest: publication.envelopeDigest,
                sourceMAC: publication.sourceMAC
            ), activity: activity)
        } catch is CancellationError {
            return
        } catch {
            SafariApprovalDiagnostics.record("publish approval vault", error: error)
            clearVaultLocked(
                coordinationLease: coordinationLease,
                activity: activity
            )
        }
    }

    private func publicationMetadata() -> PublicationMetadata? {
        guard let data = metadata.data(),
              let metadata = try? JSONDecoder().decode(
                  PublicationMetadata.self,
                  from: data
              ) else { return nil }
        return metadata
    }

    private func persistPublicationMetadata(
        _ metadata: PublicationMetadata,
        activity: SafariApprovalReconciliationActivity? = nil
    ) {
        if let activity {
            _ = try? activity.withActive { persistPublicationMetadata(metadata) }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(metadata)
        } catch {
            SafariApprovalDiagnostics.record("encode publication metadata", error: error)
            return
        }
        self.metadata.set(data)
        if !self.metadata.synchronize() {
            SafariApprovalDiagnostics.record(
                "persist publication metadata",
                error: SafariApprovalVault.Error.unavailable
            )
        }
    }

    @discardableResult
    private func clearVaultLocked(
        coordinationLease: SafariApprovalVault.CoordinationLease,
        activity: SafariApprovalReconciliationActivity? = nil
    ) -> Bool {
        if let activity {
            return (try? activity.withActive {
                clearVaultLocked(coordinationLease: coordinationLease)
            }) ?? false
        }
        let cleared: Bool
        do {
            try vault.clear(coordinationLease: coordinationLease)
            cleared = true
        } catch {
            try? vault.deleteAllKeys(
                coordinationLease: coordinationLease
            )
            cleared = false
        }
        metadata.remove()
        _ = metadata.synchronize()
        return cleared
    }

    private static let publicationMetadataKey =
        "SafariApprovalVault.hostPublicationMetadata.v1"
}
#endif
