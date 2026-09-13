// ∅ 2026 lil org

import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import OSLog
import Security

struct SafariApprovalWalletRecord: Codable, Equatable, Sendable {
    let walletID: String
    var storedKeyJSON: Data
}

struct SafariApprovalSourceSnapshot {
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

enum SafariApprovalKeyAvailability: Equatable {
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

protocol SafariApprovalKeyStoring: AnyObject {
    func store(_ key: Data, generation: UUID) throws
    func load(generation: UUID, context: LAContext) throws -> Data
    func availability(generation: UUID) -> SafariApprovalKeyAvailability
    func removeAll() throws
}

protocol SafariApprovalIntegrityKeyStoring: AnyObject {
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
    static let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    typealias Add = (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    typealias CopyMatching = (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    typealias RandomKey = () throws -> Data

    private let add: Add
    private let copyMatching: CopyMatching
    private let randomKey: RandomKey

    init(
        add: @escaping Add = SecItemAdd,
        copyMatching: @escaping CopyMatching = SecItemCopyMatching,
        randomKey: @escaping RandomKey = SafariApprovalVault.makeRandomKey
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
    static let accessibility = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
    static let accessControlFlags = SecAccessControlCreateFlags.userPresence

    typealias Add = (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    typealias CopyMatching = (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    typealias Delete = (CFDictionary) -> OSStatus

    private let add: Add
    private let copyMatching: CopyMatching
    private let delete: Delete

    init(
        add: @escaping Add = SecItemAdd,
        copyMatching: @escaping CopyMatching = SecItemCopyMatching,
        delete: @escaping Delete = SecItemDelete
    ) {
        self.add = add
        self.copyMatching = copyMatching
        self.delete = delete
    }

    func store(_ key: Data, generation: UUID) throws {
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

        var addQuery = Self.baseQuery(generation: generation)
        addQuery[kSecValueData as String] = key
        addQuery[kSecAttrAccessControl as String] = accessControl
        let status = add(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SafariApprovalVault.Error.keychainFailure(status)
        }
    }

    func load(generation: UUID, context: LAContext) throws -> Data {
        let query = Self.loadQuery(generation: generation, context: context)
        var item: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let key = item as? Data else {
            throw SafariApprovalVault.Error.keychainFailure(
                status == errSecSuccess ? errSecDecode : status
            )
        }
        return key
    }

    func availability(generation: UUID) -> SafariApprovalKeyAvailability {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query = Self.availabilityQuery(
            generation: generation,
            context: context
        )
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

    static func baseQuery(generation: UUID) -> [String: Any] {
        var query = commonQuery
        query[kSecAttrAccount as String] = generation.uuidString.lowercased()
        return query
    }

    static func loadQuery(
        generation: UUID,
        context: LAContext
    ) -> [String: Any] {
        var query = baseQuery(generation: generation)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    static func availabilityQuery(
        generation: UUID,
        context: LAContext
    ) -> [String: Any] {
        var query = baseQuery(generation: generation)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

}

final class SafariApprovalVault {

    final class CoordinationLease {
        fileprivate let owner: ObjectIdentifier
        private let lock: CrossProcessFileLock
        private let stateLock = NSLock()
        private var active = true

        fileprivate init(
            owner: ObjectIdentifier,
            lock: CrossProcessFileLock
        ) {
            self.owner = owner
            self.lock = lock
        }

        fileprivate var isActive: Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return active
        }

        func release() {
            stateLock.lock()
            guard active else {
                stateLock.unlock()
                return
            }
            active = false
            stateLock.unlock()
            lock.release()
        }

        deinit {
            release()
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
        let sourceRevision: UInt64
    }

    private struct Envelope: Codable, Equatable {
        let version: Int
        let generation: UUID
        let sourceRevision: UInt64
        let header: Data
        let catalog: Data
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    private struct SecretSnapshot: Codable {
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

    typealias Authentication = (LAContext, LAPolicy, String) async -> Bool
    typealias CanEvaluateAuthentication = (LAContext, LAPolicy) -> Bool
    typealias RandomKey = () throws -> Data
    typealias AtomicWrite = (Data, URL) throws -> Void

    private let fileURL: URL?
    private let keyStore: SafariApprovalKeyStoring
    private let authentication: Authentication
    private let canEvaluateAuthentication: CanEvaluateAuthentication
    private let randomKey: RandomKey
    private let atomicWrite: AtomicWrite
    private let coordinationLockURL: URL?
    private let lock = NSLock()

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
            await SafariApprovalVault.evaluate(
                context: $0,
                policy: $1,
                reason: $2
            )
        },
        randomKey: @escaping RandomKey = SafariApprovalVault.makeRandomKey,
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
        sourceRevision: UInt64,
        integrityKey: Data,
        coordinationLease: CoordinationLease? = nil
    ) throws -> Publication {
        try withCoordination(coordinationLease) {
            try publishCoordinated(
                source: source,
                sourceRevision: sourceRevision,
                integrityKey: integrityKey
            )
        }
    }

    private func publishCoordinated(
        source: SafariApprovalSourceSnapshot,
        sourceRevision: UInt64,
        integrityKey: Data
    ) throws -> Publication {
        guard source.catalog.isValid else { throw Error.invalidCatalog }
        guard integrityKey.count == 32 else { throw Error.invalidKey }
        let generation = UUID()
        let catalogData = try SourceWalletAccess.encodeCatalog(source.catalog)
        let header = Header(
            version: Self.envelopeVersion,
            generation: generation,
            sourceRevision: sourceRevision
        )
        let headerData = try canonicalEncoder().encode(header)
        let aad = authenticatedData(header: headerData, catalog: catalogData)
        var secret = SecretSnapshot(
            catalog: catalogData,
            password: source.password,
            wallets: source.wallets
        )
        defer { secret.resetSecrets() }
        var secretData = try canonicalEncoder().encode(secret)
        defer { secretData.resetBytes(in: 0..<secretData.count) }
        guard secretData.count <= Self.maximumEnvelopeBytes else {
            throw Error.payloadTooLarge
        }
        let sourceMAC = Self.authenticationCode(
            for: secretData,
            key: integrityKey
        )

        var key = try randomKey()
        guard key.count == 32 else { throw Error.invalidKey }
        defer { key.resetBytes(in: 0..<key.count) }

        let sealed = try AES.GCM.seal(
            secretData,
            using: SymmetricKey(data: key),
            authenticating: aad
        )
        let envelope = Envelope(
            version: header.version,
            generation: header.generation,
            sourceRevision: header.sourceRevision,
            header: headerData,
            catalog: catalogData,
            nonce: sealed.nonce.withUnsafeBytes { Data($0) },
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
        let envelopeData = try canonicalEncoder().encode(envelope)
        guard envelopeData.count <= Self.maximumEnvelopeBytes else {
            throw Error.payloadTooLarge
        }
        guard let fileURL else { throw Error.unavailable }

        lock.lock()
        defer { lock.unlock() }
        try writeTombstoneLocked()
        try deleteAllKeysLocked()
        do {
            try keyStore.store(key, generation: generation)
        } catch {
            SafariApprovalDiagnostics.record("store approval key", error: error)
            throw error
        }
        do {
            try atomicWrite(envelopeData, fileURL)
        } catch {
            SafariApprovalDiagnostics.record("write envelope", error: error)
            throw Error.unavailable
        }
        guard let committed = loadEnvelopeRecordLocked(),
              committed.data == envelopeData,
              committed.envelope == envelope else {
            SafariApprovalDiagnostics.record(
                "verify envelope",
                error: Error.invalidEnvelope
            )
            throw Error.unavailable
        }
        switch keyStore.availability(generation: generation) {
        case .present, .authenticationRequired:
            break
        case .missing:
            throw Error.keychainFailure(errSecItemNotFound)
        case .unavailable(let status):
            throw Error.keychainFailure(status)
        }
        return Publication(
            generation: generation,
            envelopeDigest: Self.digest(envelopeData),
            sourceMAC: sourceMAC
        )
    }

    func catalogAccess() -> CatalogWalletAccess? {
        lock.lock()
        defer { lock.unlock() }
        guard let envelope = loadEnvelopeLocked(),
              keyStore.availability(generation: envelope.generation)
                .permitsPublishedEnvelope,
              let catalog = decodeCatalog(envelope.catalog) else { return nil }
        return CatalogWalletAccess(
            catalog: catalog,
            generation: envelope.generation,
            sourceRevision: envelope.sourceRevision,
            catalogData: envelope.catalog
        )
    }

    func publicationStatus(
        source: SafariApprovalSourceSnapshot,
        sourceRevision: UInt64,
        expectedGeneration: UUID,
        expectedEnvelopeDigest: Data,
        expectedSourceMAC: Data,
        integrityKey: Data
    ) -> PublicationStatus {
        guard integrityKey.count == 32,
              source.catalog.isValid,
              let catalogData = try? SourceWalletAccess.encodeCatalog(
                  source.catalog
              ) else { return .stale }
        var secret = SecretSnapshot(
            catalog: catalogData,
            password: source.password,
            wallets: source.wallets
        )
        defer { secret.resetSecrets() }
        guard var secretData = try? canonicalEncoder().encode(secret),
              secretData.count <= Self.maximumEnvelopeBytes else {
            return .stale
        }
        defer { secretData.resetBytes(in: 0..<secretData.count) }
        guard Self.authenticationCode(
                  for: secretData,
                  key: integrityKey
              ) == expectedSourceMAC else {
            return .stale
        }
        lock.lock()
        defer { lock.unlock() }
        guard let record = loadEnvelopeRecordLocked() else { return .stale }
        let envelope = record.envelope
        guard envelope.generation == expectedGeneration,
              envelope.sourceRevision == sourceRevision,
              envelope.catalog == catalogData,
              Self.digest(record.data) == expectedEnvelopeDigest else {
            return .stale
        }
        switch keyStore.availability(generation: envelope.generation) {
        case .present, .authenticationRequired:
            return .current
        case .missing:
            return .stale
        case .unavailable(let status):
            return .unavailable(status)
        }
    }

    func unlock(reason: String) async -> RequestScopedWalletAccess? {
        guard case .unlocked(let access) = await unlockResult(reason: reason)
        else { return nil }
        return access
    }

    func unlockResult(reason: String) async -> WalletUnlockResult {
        let envelope: Envelope
        guard let loaded = withLock({ loadEnvelopeLocked() }) else {
            return .unavailable
        }
        envelope = loaded

        let context = LAContext()
        context.localizedCancelTitle = Strings.cancel
        guard canEvaluateAuthentication(
                  context,
                  .deviceOwnerAuthentication
              ) else { return .unavailable }
        guard await authentication(
            context,
            .deviceOwnerAuthentication,
            reason
        ) else { return .canceled }

        var key: Data
        do {
            key = try keyStore.load(
                generation: envelope.generation,
                context: context
            )
        } catch {
            SafariApprovalDiagnostics.record("load approval key", error: error)
            return .unavailable
        }
        defer { key.resetBytes(in: 0..<key.count) }
        guard key.count == 32 else { return .unavailable }

        guard let sealed = try? AES.GCM.SealedBox(
                  nonce: AES.GCM.Nonce(data: envelope.nonce),
                  ciphertext: envelope.ciphertext,
                  tag: envelope.tag
              ) else { return .unavailable }
        let aad = authenticatedData(
            header: envelope.header,
            catalog: envelope.catalog
        )
        guard var decrypted = try? AES.GCM.open(
                  sealed,
                  using: SymmetricKey(data: key),
                  authenticating: aad
              ),
              decrypted.count <= Self.maximumEnvelopeBytes else {
            return .unavailable
        }
        defer { decrypted.resetBytes(in: 0..<decrypted.count) }
        guard var secret = try? JSONDecoder().decode(
                  SecretSnapshot.self,
                  from: decrypted
              ) else { return .unavailable }
        defer { secret.resetSecrets() }
        guard
              secret.catalog == envelope.catalog,
              let catalog = decodeCatalog(envelope.catalog),
              let access = UnlockedWalletAccess(
                  catalog: catalog,
                  generation: envelope.generation,
                  sourceRevision: envelope.sourceRevision,
                  catalogData: envelope.catalog,
                  password: secret.password,
                  walletRecords: secret.wallets.map {
                      (id: $0.walletID, data: $0.storedKeyJSON)
                  }
              ) else { return .unavailable }
        let isStillCurrent = isCurrent(envelope)
        guard isStillCurrent else {
            access.invalidate()
            return .unavailable
        }
        return .unlocked(RequestScopedWalletAccess(
            access,
            isCurrent: { [weak self] in
                self?.isCurrent(envelope) == true
            },
            acquireExecutionLease: { [weak self] in
                self?.executionLease(ifCurrent: envelope)
            }
        ))
    }

    func clear(coordinationLease: CoordinationLease? = nil) throws {
        try withCoordination(coordinationLease) {
            lock.lock()
            defer { lock.unlock() }
            try writeTombstoneLocked()
            try deleteAllKeysLocked()
        }
    }

    func markUnavailable(
        coordinationLease: CoordinationLease? = nil
    ) throws {
        try withCoordination(coordinationLease) {
            lock.lock()
            defer { lock.unlock() }
            try writeTombstoneLocked()
        }
    }

    func deleteAllKeys(
        coordinationLease: CoordinationLease? = nil
    ) throws {
        try withCoordination(coordinationLease) {
            lock.lock()
            defer { lock.unlock() }
            try deleteAllKeysLocked()
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

    private func writeTombstoneLocked() throws {
        guard let fileURL else { throw Error.unavailable }
        do {
            try atomicWrite(Data(), fileURL)
        } catch {
            SafariApprovalDiagnostics.record("write tombstone", error: error)
            throw Error.unavailable
        }
        guard loadEnvelopeLocked() == nil else { throw Error.unavailable }
    }

    private func loadEnvelopeLocked() -> Envelope? {
        loadEnvelopeRecordLocked()?.envelope
    }

    private func loadEnvelopeRecordLocked() -> (envelope: Envelope, data: Data)? {
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
              header.sourceRevision == envelope.sourceRevision,
              (try? canonicalEncoder().encode(header)) == envelope.header,
              envelope.nonce.count == 12,
              envelope.tag.count == 16,
              !envelope.ciphertext.isEmpty,
              envelope.catalog.count <= Self.maximumEnvelopeBytes,
              decodeCatalog(envelope.catalog) != nil else { return nil }
        return (envelope, data)
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

    private func isCurrent(_ envelope: Envelope) -> Bool {
        withLock {
            loadEnvelopeLocked() == envelope &&
                keyStore.availability(generation: envelope.generation)
                    .permitsPublishedEnvelope
        }
    }

    private func executionLease(ifCurrent envelope: Envelope)
        -> WalletExecutionLease? {
        guard let coordinationLease = try? acquireCoordinationLease(
                  timeoutNanoseconds:
                    Self.coordinationLockTimeoutNanoseconds
              ) else { return nil }
        let current = withLock {
            loadEnvelopeLocked() == envelope &&
                keyStore.availability(generation: envelope.generation)
                    .permitsPublishedEnvelope
        }
        guard current else {
            coordinationLease.release()
            return nil
        }
        return WalletExecutionLease {
            coordinationLease.release()
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

    private func withLock<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    private func decodeCatalog(_ data: Data) -> WalletAccountCatalog? {
        guard !data.isEmpty,
              data.count <= Self.maximumEnvelopeBytes,
              let catalog = try? JSONDecoder().decode(
                  WalletAccountCatalog.self,
                  from: data
              ),
              catalog.isValid,
              (try? SourceWalletAccess.encodeCatalog(catalog)) == data else {
            return nil
        }
        return catalog
    }

    private func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func authenticatedData(header: Data, catalog: Data) -> Data {
        var result = Data()
        var headerLength = UInt64(header.count).bigEndian
        withUnsafeBytes(of: &headerLength) { result.append(contentsOf: $0) }
        result.append(header)
        var catalogLength = UInt64(catalog.count).bigEndian
        withUnsafeBytes(of: &catalogLength) { result.append(contentsOf: $0) }
        result.append(catalog)
        return result
    }

    private static func evaluate(
        context: LAContext,
        policy: LAPolicy,
        reason: String
    ) async -> Bool {
        await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { continuation in
                    context.evaluatePolicy(
                        policy,
                        localizedReason: reason
                    ) { succeeded, _ in
                        continuation.resume(returning: succeeded)
                    }
                }
            },
            onCancel: {
                context.invalidate()
            }
        )
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
final class SafariApprovalVaultHost {

    private struct PublicationMetadata: Codable {
        let generation: UUID
        let envelopeDigest: Data
        let sourceMAC: Data
    }

    typealias SynchronizeDefaults = (UserDefaults) -> Bool

    static let shared = SafariApprovalVaultHost()

    private let vault: SafariApprovalVault
    private let defaults: UserDefaults
    private let integrityKeyStore: SafariApprovalIntegrityKeyStoring
    private let synchronizeDefaults: SynchronizeDefaults
    private let sourceSnapshot: () throws -> SafariApprovalSourceSnapshot?
    private let lock = NSRecursiveLock()
    private var isStarted = false

    init(
        vault: SafariApprovalVault = .shared,
        walletsManager: WalletsManager = .shared,
        defaults: UserDefaults = .standard,
        integrityKeyStore: SafariApprovalIntegrityKeyStoring =
            SafariApprovalIntegrityKeychainStore(),
        synchronizeDefaults: @escaping SynchronizeDefaults = {
            $0.synchronize()
        },
        sourceSnapshot: (() throws -> SafariApprovalSourceSnapshot?)? = nil
    ) {
        self.vault = vault
        self.defaults = defaults
        self.integrityKeyStore = integrityKeyStore
        self.synchronizeDefaults = synchronizeDefaults
        self.sourceSnapshot = sourceSnapshot ?? {
            try walletsManager.safariApprovalSourceSnapshot()
        }
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isStarted else { return }
        isStarted = true
        guard let coordinationLease = acquireCoordinationLease()
        else { return }
        defer { coordinationLease.release() }
        reconcileLocked(coordinationLease: coordinationLease)
    }

    func reconcile() {
        lock.lock()
        defer { lock.unlock() }
        guard let coordinationLease = acquireCoordinationLease()
        else { return }
        defer { coordinationLease.release() }
        reconcileLocked(coordinationLease: coordinationLease)
    }

    private func acquireCoordinationLease() -> SafariApprovalVault.CoordinationLease? {
        do {
            return try vault.acquireCoordinationLease()
        } catch {
            SafariApprovalDiagnostics.record("acquire coordination lock", error: error)
            return nil
        }
    }

    func performSourceMutation<Result>(
        _ operation: () throws -> Result
    ) throws -> Result {
        lock.lock()
        defer { lock.unlock() }
        let coordinationLease: SafariApprovalVault.CoordinationLease
        do {
            coordinationLease = try vault.acquireCoordinationLease()
        } catch {
            SafariApprovalDiagnostics.record("coordinate source mutation", error: error)
            throw SafariApprovalVault.Error.unavailable
        }
        defer { coordinationLease.release() }
        let publicationReady = try willMutateSourceLocked(
            coordinationLease: coordinationLease
        )
        let result = try operation()
        if publicationReady {
            reconcileLocked(coordinationLease: coordinationLease)
        }
        return result
    }

    private func reconcileLocked(
        coordinationLease: SafariApprovalVault.CoordinationLease
    ) {
        var source: SafariApprovalSourceSnapshot
        do {
            guard let loaded = try sourceSnapshot()
            else {
                clearVaultLocked(
                    coordinationLease: coordinationLease
                )
                return
            }
            source = loaded
        } catch {
            SafariApprovalDiagnostics.record("load source snapshot", error: error)
            clearVaultLocked(
                coordinationLease: coordinationLease
            )
            return
        }
        defer { source.resetSecrets() }

        let revision = sourceRevision(coordinationLease: coordinationLease)
        guard revision > 0 else { return }
        var integrityKey: Data
        do {
            integrityKey = try integrityKeyStore.loadOrCreate()
        } catch {
            SafariApprovalDiagnostics.record("load integrity key", error: error)
            clearVaultLocked(
                coordinationLease: coordinationLease
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
                coordinationLease: coordinationLease
            )
            return
        }

        if let metadata = publicationMetadata() {
            switch vault.publicationStatus(
                source: source,
                sourceRevision: revision,
                expectedGeneration: metadata.generation,
                expectedEnvelopeDigest: metadata.envelopeDigest,
                expectedSourceMAC: metadata.sourceMAC,
                integrityKey: integrityKey
            ) {
            case .current:
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
            guard synchronizeDefaults(defaults) else {
                throw SafariApprovalVault.Error.unavailable
            }
            let publication = try vault.publish(
                source: source,
                sourceRevision: revision,
                integrityKey: integrityKey,
                coordinationLease: coordinationLease
            )
            guard persistPublicationMetadata(PublicationMetadata(
                generation: publication.generation,
                envelopeDigest: publication.envelopeDigest,
                sourceMAC: publication.sourceMAC
            )) else {
                throw SafariApprovalVault.Error.unavailable
            }
        } catch {
            SafariApprovalDiagnostics.record("publish approval vault", error: error)
            clearVaultLocked(
                coordinationLease: coordinationLease
            )
        }
    }

    private func willMutateSourceLocked(
        coordinationLease: SafariApprovalVault.CoordinationLease
    ) throws -> Bool {
        do {
            try vault.clear(coordinationLease: coordinationLease)
        } catch {
            throw SafariApprovalVault.Error.unavailable
        }
        let current = sourceRevision(coordinationLease: coordinationLease)
        guard current > 0, current < UInt64.max else {
            clearVaultLocked(
                coordinationLease: coordinationLease
            )
            return false
        }
        defaults.set(
            NSNumber(value: current + 1),
            forKey: Self.sourceRevisionKey
        )
        defaults.removeObject(forKey: Self.publicationMetadataKey)
        guard synchronizeDefaults(defaults) else {
            SafariApprovalDiagnostics.record(
                "persist source revision",
                error: SafariApprovalVault.Error.unavailable
            )
            clearVaultLocked(
                coordinationLease: coordinationLease
            )
            return false
        }
        return true
    }

    private func sourceRevision(
        coordinationLease: SafariApprovalVault.CoordinationLease
    ) -> UInt64 {
        if let value = defaults.object(
            forKey: Self.sourceRevisionKey
        ) as? NSNumber, value.uint64Value > 0 {
            return value.uint64Value
        }
        defaults.set(NSNumber(value: UInt64(1)), forKey: Self.sourceRevisionKey)
        guard synchronizeDefaults(defaults) else {
            SafariApprovalDiagnostics.record(
                "initialize source revision",
                error: SafariApprovalVault.Error.unavailable
            )
            clearVaultLocked(
                coordinationLease: coordinationLease
            )
            return 0
        }
        return 1
    }

    private func publicationMetadata() -> PublicationMetadata? {
        guard let data = defaults.data(forKey: Self.publicationMetadataKey),
              let metadata = try? JSONDecoder().decode(
                  PublicationMetadata.self,
                  from: data
              ) else { return nil }
        return metadata
    }

    private func persistPublicationMetadata(
        _ metadata: PublicationMetadata
    ) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(metadata)
        } catch {
            SafariApprovalDiagnostics.record("encode publication metadata", error: error)
            return false
        }
        defaults.set(data, forKey: Self.publicationMetadataKey)
        guard synchronizeDefaults(defaults) else {
            SafariApprovalDiagnostics.record(
                "persist publication metadata",
                error: SafariApprovalVault.Error.unavailable
            )
            defaults.removeObject(forKey: Self.publicationMetadataKey)
            _ = synchronizeDefaults(defaults)
            return false
        }
        return true
    }

    @discardableResult
    private func clearVaultLocked(
        coordinationLease: SafariApprovalVault.CoordinationLease
    ) -> Bool {
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
        defaults.removeObject(forKey: Self.publicationMetadataKey)
        _ = synchronizeDefaults(defaults)
        return cleared
    }

    private static let sourceRevisionKey =
        "SafariApprovalVault.hostSourceRevision.v1"
    private static let publicationMetadataKey =
        "SafariApprovalVault.hostPublicationMetadata.v1"
}
#endif
