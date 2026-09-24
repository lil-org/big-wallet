// ∅ 2026 lil org

import Foundation
import CryptoKit

final class ExtensionRequestFileStore {
    enum WalletAuthorityRemovalError: Error {
        case unavailable
    }

    typealias AtomicWrite = (Data, URL) throws -> Void
    typealias SynchronizePublishedFile = (URL) throws -> Void
    typealias ReadData = (URL) throws -> Data
    typealias ReadFileSize = (URL) throws -> Int?
    typealias RemoveItem = (URL) throws -> Void
    typealias ParseRequest = ([String: Any]) -> SafariRequest?

    struct Dependencies {
        let clock: () -> Date
        let token: () -> UUID
        let crossProcessLock: CrossProcessFileLock?
        let crossProcessLockTimeoutNanoseconds: UInt64
        let crossProcessLockPollNanoseconds: UInt64
        let atomicWrite: AtomicWrite?
        let synchronizePublishedFile: SynchronizePublishedFile?
        let persistenceOperations: DurableProfilePersistence.Operations
        let readData: ReadData
        let readFileSize: ReadFileSize
        let removeItem: RemoveItem
        let parseRequest: ParseRequest

        init(
            clock: @escaping () -> Date = Date.init,
            token: @escaping () -> UUID = UUID.init,
            crossProcessLock: CrossProcessFileLock? = nil,
            crossProcessLockTimeoutNanoseconds: UInt64 = 1_000_000_000,
            crossProcessLockPollNanoseconds: UInt64 = 10_000_000,
            atomicWrite: AtomicWrite? = nil,
            synchronizePublishedFile: SynchronizePublishedFile? = nil,
            persistenceOperations: DurableProfilePersistence.Operations = .live,
            readData: @escaping ReadData = ExtensionRequestFileStore.defaultReadData,
            readFileSize: @escaping ReadFileSize = ExtensionRequestFileStore.defaultReadFileSize,
            removeItem: @escaping RemoveItem = ExtensionRequestFileStore.defaultRemoveItem,
            parseRequest: @escaping ParseRequest = { SafariRequest(json: $0) }
        ) {
            self.clock = clock
            self.token = token
            self.crossProcessLock = crossProcessLock
            self.crossProcessLockTimeoutNanoseconds = crossProcessLockTimeoutNanoseconds
            self.crossProcessLockPollNanoseconds = crossProcessLockPollNanoseconds
            self.atomicWrite = atomicWrite
            self.synchronizePublishedFile = synchronizePublishedFile
            self.persistenceOperations = persistenceOperations
            self.readData = readData
            self.readFileSize = readFileSize
            self.removeItem = removeItem
            self.parseRequest = parseRequest
        }
    }

    private struct ReceiptIdentity {
        let nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce
        let runtimeInstanceIdentifier: UUID
    }

    private struct ProfileState: Codable {
        let schemaVersion: Int
        let workflowVersion: Int
        let profileIdentifier: UUID?
        let authorityEpoch: UUID
        var authoritySequence: Int
        var origins: [String: OriginState]
        var mutationReceipts: [MutationReceipt]
        var records: [Record]
        var invalidOrigins = Set<String>()
        var invalidOriginsContainer = false

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, workflowVersion, profileIdentifier, authorityEpoch
            case authoritySequence, origins, mutationReceipts, records
        }

        init(profileIdentifier: UUID?, authorityEpoch: UUID) {
            schemaVersion = ExtensionRequestFileStore.profileSchemaVersion
            workflowVersion = ExtensionBridge.workflowVersion
            self.profileIdentifier = profileIdentifier
            self.authorityEpoch = authorityEpoch
            authoritySequence = 0
            origins = [:]
            mutationReceipts = []
            records = []
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            workflowVersion = try values.decode(Int.self, forKey: .workflowVersion)
            profileIdentifier = try values.decodeIfPresent(UUID.self, forKey: .profileIdentifier)
            authorityEpoch = try values.decode(UUID.self, forKey: .authorityEpoch)
            authoritySequence = try values.decode(Int.self, forKey: .authoritySequence)
            mutationReceipts = try values.decode([MutationReceipt].self, forKey: .mutationReceipts)
            records = try values.decode([Record].self, forKey: .records)
            if let decodedOrigins = try? values.decode([String: DecodedOrigin].self, forKey: .origins) {
                origins = decodedOrigins.compactMapValues(\.value)
                invalidOrigins = Set(decodedOrigins.filter { $0.value.value == nil }.keys)
            } else {
                origins = [:]
                invalidOriginsContainer = true
            }
        }
    }

    private struct DecodedOrigin: Decodable {
        let value: OriginState?

        init(from decoder: Decoder) throws {
            value = try? OriginState(from: decoder)
        }
    }

    private struct OriginState: Codable {
        var ethereumAccount: WalletAccountDescriptor?
        var ethereumChainId = "0x1"
        var solanaAccount: WalletAccountDescriptor?
        var revisions: ExtensionBridge.ProviderRevisions

        var isDefaultDisconnected: Bool {
            ethereumAccount == nil && solanaAccount == nil && ethereumChainId == "0x1"
        }
    }

    private struct MutationReceipt: Codable {
        let configurationKey: String
        let provider: InpageProvider
        let attempt: String
        let expected: ExtensionBridge.AuthorityVersion
        let createdAt: Date
    }

    private struct ValidatedProfile {
        var state: ProfileState
        var parsedRequests: [ExtensionBridge.Handle: SafariRequest]

        func request(for record: Record) -> SafariRequest? {
            guard record.state.requestData != nil else { return nil }
            return parsedRequests[record.handle]
        }

        mutating func complete(at index: Int, response: Data, date: Date) {
            state.records[index].complete(response: response, at: date)
            parsedRequests.removeValue(forKey: state.records[index].handle)
        }
    }

    private struct Record: Codable {
        struct NativeApproval: Codable {
            let approvedAt: Date
            let receipt: ExtensionBridge.NativeDeliveryReceipt
        }

        enum PendingApproval: Codable {
            case unowned
            case delivered(ExtensionBridge.NativeDeliveryReceipt)
        }

        enum ClaimedApproval: Codable {
            case ordinary
            case native(NativeApproval, context: ExtensionBridge.NativeExecutionContext)

            var broadcast: BroadcastApproval {
                switch self {
                case .ordinary:
                    return .ordinary
                case .native(let approval, _):
                    return .native(approval)
                }
            }
        }

        enum BroadcastApproval: Codable {
            case ordinary
            case native(NativeApproval)
        }

        enum State: Codable {
            case pending(request: Data, approval: PendingApproval)
            case claimed(claimID: UUID, request: Data, approval: ClaimedApproval)
            case broadcastPrepared(
                claimID: UUID,
                request: Data,
                recoveryResponse: Data,
                approval: BroadcastApproval
            )
            case completed(since: Date, response: Data, acknowledged: Bool)

            var requestData: Data? {
                switch self {
                case .pending(let request, _), .claimed(_, let request, _),
                     .broadcastPrepared(_, let request, _, _):
                    return request
                case .completed:
                    return nil
                }
            }

            var responseData: Data? {
                switch self {
                case .broadcastPrepared(_, _, let response, _),
                     .completed(_, let response, _):
                    return response
                case .pending, .claimed:
                    return nil
                }
            }

            var isActive: Bool {
                switch self {
                case .pending, .claimed, .broadcastPrepared:
                    return true
                case .completed:
                    return false
                }
            }
        }

        let id: Int
        let profileIdentifier: UUID?
        let enqueueAttempt: String
        let requestToken: UUID
        let host: String
        let configurationKey: String
        let requestFingerprint: Data
        let authority: ExtensionBridge.AuthorityVersion
        let authorizedAccount: WalletAccountDescriptor?
        var executionDeadline: Date?
        var revisions: ExtensionBridge.ProviderRevisions { authority.revisions }
        let admissionCreatedAt: Date
        var createdAt: Date
        var state: State
        let nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce

        var nativeApproval: NativeApproval? {
            switch state {
            case .claimed(_, _, .native(let approval, _)),
                 .broadcastPrepared(_, _, _, .native(let approval)):
                return approval
            case .pending, .claimed, .broadcastPrepared, .completed:
                return nil
            }
        }

        var nativeDeliveryReceipt: ExtensionBridge.NativeDeliveryReceipt? {
            if case .pending(_, .delivered(let receipt)) = state {
                return receipt
            }
            return nativeApproval?.receipt
        }

        var nativeExecutionContext: ExtensionBridge.NativeExecutionContext? {
            switch state {
            case .claimed(_, _, .native(_, let context)):
                return context
            case .pending, .claimed, .broadcastPrepared, .completed:
                return nil
            }
        }

        var responseAcknowledged: Bool {
            guard case .completed(_, _, let acknowledged) = state else {
                return false
            }
            return acknowledged
        }

        var handle: ExtensionBridge.Handle {
            ExtensionBridge.Handle(
                id: id,
                token: .init(value: requestToken),
                profileIdentifier: profileIdentifier
            )
        }

        @discardableResult
        mutating func restorePendingClaim() -> Bool {
            guard case .claimed(_, let request, .ordinary) = state else {
                return false
            }
            state = .pending(request: request, approval: .unowned)
            return true
        }

        mutating func complete(response: Data, at date: Date) {
            state = .completed(
                since: max(createdAt, date),
                response: response,
                acknowledged: false
            )
        }
    }

    private enum ProfileRead {
        case state(ValidatedProfile)
        case corrupt
        case unavailable
    }

    private enum ProfileDataRead {
        case missing
        case data(Data)
        case corrupt
        case unavailable
    }

    private enum WriteFailureRecovery {
        case none
        case readBack
    }

    private enum PendingDeadlineTransition {
        case active(SafariRequest), expired, unavailable
    }

    private enum OperationLockStatus {
        case held, unlocked, unsafe, unavailable
    }

    private enum RegularFileStatus {
        case missing, regular, unsafe, unavailable
    }

    private enum DirectoryStatus {
        case missing, directory, unsafe, unavailable
    }

    private struct ProfileFileIdentity {
        let identifier: UUID?
    }

    private struct ProfileFileCandidate {
        let url: URL
        let identity: ProfileFileIdentity
    }

    private static let profileSchemaVersion = 8
    private static let profileDirectoryName = "profiles-v8"
    private static let operationLockDirectoryName = "operation-locks-v8"
    private static let maximumProfileBytes =
        ExtensionBridge.maximumRetainedBytes + ExtensionRequestFileStore.maximumAuthorityBytes + ExtensionRequestFileStore.maximumMutationReceiptBytes + 64 * 1024
    private static let maximumOrigins = 512
    private static let maximumAuthorityBytes = 1_024 * 1_024
    private static let maximumMutationReceipts = 256
    private static let maximumMutationReceiptBytes = 256 * 1_024
    private static let mutationReceiptLifetime: TimeInterval = 60 * 60
    private static let maximumRevision = 9_007_199_254_740_991
    private static let executionLifetime: TimeInterval = 150
    private static let futureSkew = ExtensionBridge.admissionDeadlineFutureSkew

    private let rootURL: URL?
    private let clock: () -> Date
    private let token: () -> UUID
    private let storeLock: CrossProcessFileLock?
    private let lockTimeout: UInt64
    private let lockPoll: UInt64
    private let atomicWrite: AtomicWrite
    private let synchronizePublishedFile: SynchronizePublishedFile
    private let readData: ReadData
    private let readFileSize: ReadFileSize
    private let removeItem: RemoveItem
    private let parseRequest: ParseRequest
    private let fileManager = FileManager.default

    static func defaultReadData(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    static func defaultReadFileSize(_ url: URL) throws -> Int? {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize
    }

    static func defaultRemoveItem(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    convenience init(
        containerURL: URL?,
        dependencies: Dependencies = .init()
    ) {
        self.init(
            rootURL: containerURL?
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("BigWalletExtensionBridge", isDirectory: true),
            directoryBoundary: containerURL,
            dependencies: dependencies
        )
    }

    init(
        rootURL: URL?,
        directoryBoundary: URL?,
        dependencies: Dependencies = .init()
    ) {
        self.rootURL = rootURL
        clock = dependencies.clock
        token = dependencies.token
        lockTimeout = dependencies.crossProcessLockTimeoutNanoseconds
        lockPoll = dependencies.crossProcessLockPollNanoseconds
        let persistence = directoryBoundary.map {
            DurableProfilePersistence(
                directoryBoundary: $0,
                operations: dependencies.persistenceOperations
            )
        }
        atomicWrite = dependencies.atomicWrite ?? { data, url in
            guard let persistence else { throw CocoaError(.fileWriteUnknown) }
            try persistence.replace(data, at: url)
        }
        synchronizePublishedFile = dependencies.synchronizePublishedFile ?? { url in
            guard let persistence else { throw CocoaError(.fileWriteUnknown) }
            try persistence.synchronizePublishedFile(at: url)
        }
        readData = dependencies.readData
        readFileSize = dependencies.readFileSize
        removeItem = dependencies.removeItem
        parseRequest = dependencies.parseRequest
        storeLock = dependencies.crossProcessLock ?? rootURL.map {
            CrossProcessFileLock(fileURL: $0.appendingPathComponent("bridge-v8.lock"))
        }
    }

    private enum AuthorityObservation {
        case snapshot(ExtensionBridge.AuthoritySnapshot), missing, needsRepair, unavailable
    }

    private func observeAuthority(configurationKey: String, profileIdentifier: UUID?) -> AuthorityObservation {
        guard let rootURL, let storeLock else { return .unavailable }
        switch directoryStatus(at: rootURL) {
        case .missing: return .missing
        case .directory: break
        case .unsafe, .unavailable: return .unavailable
        }
        switch regularFileStatusLocked(at: rootURL.appendingPathComponent("bridge-v8.lock")) {
        case .missing:
            return directoryStatus(at: profileDirectoryURL) == .missing ? .missing : .unavailable
        case .regular: break
        case .unsafe, .unavailable: return .unavailable
        }
        guard (try? storeLock.tryAcquireExisting()) == true else { return .unavailable }
        defer { storeLock.release() }
        switch directoryStatus(at: profileDirectoryURL) {
        case .missing: return .missing
        case .directory: break
        case .unsafe, .unavailable: return .unavailable
        }
        let url = profileURL(profileIdentifier)
        switch regularFileStatusLocked(at: url) {
        case .missing: return .missing
        case .regular: break
        case .unsafe, .unavailable: return .unavailable
        }
        switch readProfileFileLocked(at: url,
            profileIdentifier: profileIdentifier, now: clock(), recover: false,
            normalizeDates: false) {
        case .state(let profile):
            return .snapshot(authoritySnapshot(profile.state, configurationKey: configurationKey))
        case .corrupt:
            return .needsRepair
        case .unavailable:
            return .unavailable
        }
    }

    func configurationSnapshot(
        configurationKey: String,
        profileIdentifier: UUID?
    ) -> ExtensionBridge.AuthorityReadResult {
        guard validConfigurationKey(configurationKey) else { return .unavailable }
        switch observeAuthority(configurationKey: configurationKey, profileIdentifier: profileIdentifier) {
        case .snapshot(let snapshot): return .snapshot(snapshot)
        case .unavailable: return .unavailable
        case .missing, .needsRepair: break
        }
        return withLock(or: .unavailable) {
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: profileIdentifier, now: clock(), recover: true
            ) else { return .unavailable }
            let url = profileURL(profileIdentifier)
            if case .missing = regularFileStatusLocked(at: url) {
                guard writeProfileLocked(profile, failureRecovery: .readBack) else { return .unavailable }
            }
            return .snapshot(authoritySnapshot(profile.state, configurationKey: configurationKey))
        }
    }

    func revoke(
        configurationKey: String,
        provider: InpageProvider,
        attempt: String,
        expected: ExtensionBridge.AuthorityVersion,
        profileIdentifier: UUID?
    ) -> ExtensionBridge.AuthorityMutationResult {
        withLock(or: .unavailable) {
            let now = clock()
            guard validConfigurationKey(configurationKey),
                  provider == .ethereum || provider == .solana,
                  ExtensionBridge.isValidEnqueueAttempt(attempt),
                  case .state(var profile) = readProfileLocked(
                    profileIdentifier: profileIdentifier, now: now, recover: true
                  ) else { return .unavailable }
            guard persistProfileIdentityIfMissing(profile) else { return .unavailable }
            let current = authoritySnapshot(profile.state, configurationKey: configurationKey)
            if let receipt = profile.state.mutationReceipts.first(where: { $0.attempt == attempt }) {
                guard receipt.configurationKey == configurationKey,
                      receipt.provider == provider, receipt.expected == expected,
                      synchronizeProfileLocked(profileIdentifier) else { return .unavailable }
                return .revoked(current)
            }
            guard authorityMatches(expected, current: current.version, provider: provider) else {
                return .stale(current)
            }
            guard pinOrigin(in: &profile.state, configurationKey: configurationKey, now: now),
                  let revision = nextRevision(in: &profile.state),
                  var origin = profile.state.origins[configurationKey] else { return .unavailable }
            if provider == .ethereum {
                origin.ethereumAccount = nil
                origin.revisions = revisions(ethereum: revision, solana: origin.revisions.solana)
            } else {
                origin.solanaAccount = nil
                origin.revisions = revisions(ethereum: origin.revisions.ethereum, solana: revision)
            }
            profile.state.origins[configurationKey] = origin
            profile.state.mutationReceipts.append(.init(
                configurationKey: configurationKey, provider: provider,
                attempt: attempt, expected: expected, createdAt: now
            ))
            while profile.state.mutationReceipts.count > Self.maximumMutationReceipts ||
                (try? Self.encode(profile.state.mutationReceipts).count).map({ $0 > Self.maximumMutationReceiptBytes }) == true {
                profile.state.mutationReceipts.removeFirst()
            }
            guard invalidateStaleRequests(in: &profile, configurationKey: configurationKey, excluding: nil, now: now),
                  writeProfileLocked(profile, failureRecovery: .readBack) else { return .unavailable }
            return .revoked(authoritySnapshot(profile.state, configurationKey: configurationKey))
        }
    }

    func withWalletSourceMutation<Result>(
        _ mutation: (_ revokeAuthority: (WalletAuthorityRemoval) throws -> Void) throws -> Result
    ) throws -> Result {
        try withRequiredLock {
            try mutation { removal in
                try revokeWalletAuthorityLocked(matching: removal)
            }
        }
    }

    func withRevokedWalletAuthority<Result>(
        matching removal: WalletAuthorityRemoval,
        sourceMutation: () throws -> Result
    ) throws -> Result {
        try withWalletSourceMutation { revoke in
            try revoke(removal)
            return try sourceMutation()
        }
    }

    private func revokeWalletAuthorityLocked(matching removal: WalletAuthorityRemoval) throws {
        switch removal {
        case .wallet(let id):
            guard !id.isEmpty, id.utf8.count <= 256 else {
                throw WalletAuthorityRemovalError.unavailable
            }
        case .accounts(let accounts):
            guard accounts.allSatisfy(\.isValid) else {
                throw WalletAuthorityRemovalError.unavailable
            }
            if accounts.isEmpty { return }
        }
        let now = clock()
        let candidates = try discoverProfileCandidatesForRemovalLocked()
        var profiles = [ValidatedProfile]()
        for candidate in candidates {
            guard case .regular = regularFileStatusLocked(at: candidate.url),
                  case .state(let profile) = readProfileFileLocked(
                    at: candidate.url, profileIdentifier: candidate.identity.identifier,
                    now: now, recover: true, normalizeDates: false
                  ) else { throw WalletAuthorityRemovalError.unavailable }
            profiles.append(profile)
        }
        for var profile in profiles {
            var changedOrigins = [String]()
            for key in profile.state.origins.keys.sorted() {
                guard var origin = profile.state.origins[key] else { continue }
                let ethereum = origin.ethereumAccount.map(removal.matches) == true
                let solana = origin.solanaAccount.map(removal.matches) == true
                guard ethereum || solana else { continue }
                if ethereum {
                    guard let revision = nextRevision(in: &profile.state) else {
                        throw WalletAuthorityRemovalError.unavailable
                    }
                    origin.ethereumAccount = nil
                    origin.revisions = revisions(ethereum: revision, solana: origin.revisions.solana)
                }
                if solana {
                    guard let revision = nextRevision(in: &profile.state) else {
                        throw WalletAuthorityRemovalError.unavailable
                    }
                    origin.solanaAccount = nil
                    origin.revisions = revisions(ethereum: origin.revisions.ethereum, solana: revision)
                }
                profile.state.origins[key] = origin
                changedOrigins.append(key)
            }
            for key in changedOrigins {
                guard invalidateStaleRequests(in: &profile, configurationKey: key, excluding: nil, now: now) else {
                    throw WalletAuthorityRemovalError.unavailable
                }
            }
            var changed = !changedOrigins.isEmpty
            for index in profile.state.records.indices {
                let record = profile.state.records[index]
                switch record.state {
                case .pending, .claimed:
                    guard let request = profile.request(for: record),
                          removalInvalidates(request, matching: removal) else { continue }
                    guard let response = boundedResponseData(ResponseToExtension(
                        for: request, payload: .error(.init(message: Strings.providerNotReady, code: 4100))
                    ), request: request) else { throw WalletAuthorityRemovalError.unavailable }
                    profile.complete(at: index, response: response, date: now)
                    changed = true
                case .broadcastPrepared, .completed:
                    break
                }
            }
            if changed, !writeProfileLocked(profile, failureRecovery: .readBack) {
                throw WalletAuthorityRemovalError.unavailable
            }
            guard synchronizeProfileLocked(profile.state.profileIdentifier) else {
                throw WalletAuthorityRemovalError.unavailable
            }
        }
    }

    private func removalInvalidates(_ request: SafariRequest, matching removal: WalletAuthorityRemoval) -> Bool {
        switch request.body {
        case .ethereum(let body):
            switch body.method {
            case .requestAccounts:
                return request.authorizedAccount.map(removal.matches) ?? true
            case .signMessage, .signPersonalMessage, .signTypedMessage, .signTransaction:
                return request.authorizedAccount.map(removal.matches) == true
            case .addEthereumChain, .switchEthereumChain, .ecRecover:
                return false
            }
        case .solana(let body):
            if body.method == .connect {
                return request.authorizedAccount.map(removal.matches) ?? true
            }
            return request.authorizedAccount.map(removal.matches) == true
        case .unknown:
            return true
        }
    }

    private func discoverProfileCandidatesForRemovalLocked() throws -> [ProfileFileCandidate] {
        switch directoryStatus(at: profileDirectoryURL) {
        case .missing: return []
        case .directory: break
        case .unsafe, .unavailable: throw WalletAuthorityRemovalError.unavailable
        }
        do {
            return try fileManager.contentsOfDirectory(
                at: profileDirectoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
                guard let identity = profileFileIdentity(for: url) else { return nil }
                return ProfileFileCandidate(url: url, identity: identity)
            }
        } catch {
            throw WalletAuthorityRemovalError.unavailable
        }
    }

    func listRecoveryRequests(profileIdentifier: UUID?) -> ExtensionBridge.RecoveryRequestsResult {
        withLock(or: .unavailable) {
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: profileIdentifier, now: clock(), recover: true
            ) else { return .unavailable }
            let active = profile.state.records.filter(\.state.isActive)
            let completed = profile.state.records.filter { !$0.state.isActive && !$0.responseAcknowledged }
            let manual = completed.filter { isManualSwitch($0, in: profile) }
            let ordinary = completed.reversed().filter { !isManualSwitch($0, in: profile) }
            let recovery = active + (manual + ordinary).prefix(max(0, ExtensionBridge.maximumRetainedRequests - active.count))
            return .available(recovery.map { record in
                .init(handle: record.handle, configurationKey: record.configurationKey,
                      manual: isManualSwitch(record, in: profile), state: manualSwitchRequest(record).state)
            })
        }
    }

    func authorityIsCurrent(handle: ExtensionBridge.Handle) -> Bool {
        withLock(or: false) {
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier, now: clock(), recover: true
            ), let record = profile.state.records.first(where: { $0.handle == handle }),
               record.state.isActive else { return false }
            return authorityIsCurrent(record, in: profile.state)
        }
    }

    private func persistProfileIdentityIfMissing(_ profile: ValidatedProfile) -> Bool {
        switch regularFileStatusLocked(at: profileURL(profile.state.profileIdentifier)) {
        case .missing: return writeProfileLocked(profile, failureRecovery: .readBack)
        case .regular: return true
        case .unsafe, .unavailable: return false
        }
    }

    private func validConfigurationKey(_ value: String) -> Bool {
        guard value.utf8.count <= 4_096, let url = URL(string: value) else { return false }
        let host: String
        if url.scheme == "file" { host = value }
        else if let separator = value.range(of: "://") { host = String(value[separator.upperBound...]) }
        else { return false }
        return ExtensionBridge.isValidIdentity(host: host, configurationKey: value)
    }

    private func revisions(ethereum: Int, solana: Int) -> ExtensionBridge.ProviderRevisions {
        ExtensionBridge.ProviderRevisions(rawValue: ["ethereum": ethereum, "solana": solana])!
    }

    private func authoritySnapshot(_ profile: ProfileState, configurationKey: String) -> ExtensionBridge.AuthoritySnapshot {
        let origin = profile.origins[configurationKey]
        let context = Data(SHA256.hash(data: Data(
            (profile.authorityEpoch.uuidString.lowercased() + "\n" + configurationKey).utf8
        ))).map { String(format: "%02x", $0) }.joined()
        return .init(
            version: .init(context: context, revisions: origin?.revisions ?? revisions(
                ethereum: profile.authoritySequence, solana: profile.authoritySequence
            )),
            ethereumAccount: origin?.ethereumAccount,
            ethereumChainId: origin?.ethereumChainId ?? "0x1",
            solanaAccount: origin?.solanaAccount
        )
    }

    private func authorityMatches(
        _ expected: ExtensionBridge.AuthorityVersion,
        current: ExtensionBridge.AuthorityVersion,
        provider: InpageProvider,
        requestName: String? = nil
    ) -> Bool {
        guard expected.context == current.context else { return false }
        if provider == .ethereum && requestName == SafariRequest.Ethereum.Method.ecRecover.rawValue {
            return true
        }
        switch provider {
        case .ethereum: return expected.revisions.ethereum == current.revisions.ethereum
        case .solana: return expected.revisions.solana == current.revisions.solana
        case .unknown, .multiple: return expected.revisions == current.revisions
        }
    }

    private func authorityIsCurrent(_ record: Record, in profile: ProfileState) -> Bool {
        authorityStatus(record, in: profile) == .current
    }

    private enum AuthorityStatus { case current, stale, inconsistentGrant }

    private func authorityStatus(_ record: Record, in profile: ProfileState) -> AuthorityStatus {
        guard let data = record.state.requestData,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providerName = raw["provider"] as? String,
              let provider = InpageProvider(rawValue: providerName),
              let name = raw["name"] as? String else { return .stale }
        let snapshot = authoritySnapshot(profile, configurationKey: record.configurationKey)
        guard authorityMatches(record.authority, current: snapshot.version,
                               provider: provider, requestName: name) else { return .stale }
        let account: WalletAccountDescriptor?
        let requiresGrant: Bool
        switch provider {
        case .ethereum:
            guard let method = SafariRequest.Ethereum.Method(rawValue: name) else { return .stale }
            switch method {
            case .ecRecover: return .current
            case .requestAccounts, .addEthereumChain, .switchEthereumChain: requiresGrant = false
            default: requiresGrant = true
            }
            account = snapshot.ethereumAccount
        case .solana:
            requiresGrant = name != SafariRequest.Solana.Method.connect.rawValue
            account = snapshot.solanaAccount
        case .unknown, .multiple:
            return .current
        }
        return (!requiresGrant || account != nil) && record.authorizedAccount == account
            ? .current : .inconsistentGrant
    }

    private func nextRevision(in profile: inout ProfileState) -> Int? {
        guard profile.authoritySequence < Self.maximumRevision else { return nil }
        profile.authoritySequence += 1
        return profile.authoritySequence
    }

    @discardableResult
    private func reclaimAuthority(in profile: inout ProfileState, now: Date) -> Bool {
        let previousCount = profile.mutationReceipts.count
        profile.mutationReceipts.removeAll { now.timeIntervalSince($0.createdAt) >= Self.mutationReceiptLifetime }
        let referenced = Set(profile.records.map(\.configurationKey) + profile.mutationReceipts.map(\.configurationKey))
        let removable = profile.origins.filter { $0.value.isDefaultDisconnected && !referenced.contains($0.key) }.map(\.key)
        if !removable.isEmpty, nextRevision(in: &profile) != nil {
            for key in removable { profile.origins.removeValue(forKey: key) }
            return true
        }
        return previousCount != profile.mutationReceipts.count
    }

    private func pinOrigin(in profile: inout ProfileState, configurationKey: String, now: Date) -> Bool {
        if profile.origins[configurationKey] != nil { return true }
        profile.origins[configurationKey] = .init(revisions: revisions(
            ethereum: profile.authoritySequence, solana: profile.authoritySequence
        ))
        if authorityFits(profile.origins) { return true }
        let referenced = Set(profile.records.map(\.configurationKey) + profile.mutationReceipts.map(\.configurationKey))
        let removable = profile.origins.filter { key, origin in
            key != configurationKey && !referenced.contains(key) &&
                origin.ethereumAccount == nil && origin.solanaAccount == nil
        }.map(\.key).sorted()
        guard !removable.isEmpty, nextRevision(in: &profile) != nil else { return false }
        for key in removable {
            profile.origins.removeValue(forKey: key)
            if authorityFits(profile.origins) { return true }
        }
        return false
    }

    private func authorityFits(_ origins: [String: OriginState]) -> Bool {
        origins.count <= Self.maximumOrigins &&
            (try? Self.encode(origins).count).map { $0 <= Self.maximumAuthorityBytes } == true
    }

    private func requestIsAuthorized(_ request: SafariRequest, by snapshot: ExtensionBridge.AuthoritySnapshot) -> Bool {
        switch request.body {
        case .ethereum(let body):
            switch body.method {
            case .requestAccounts, .addEthereumChain, .switchEthereumChain, .ecRecover:
                return true
            case .signMessage, .signPersonalMessage, .signTypedMessage, .signTransaction:
                guard let account = snapshot.ethereumAccount,
                      account.coin.normalizedAddress(body.address) == account.normalizedAddress else { return false }
                if let chain = body.currentChainId, String.hex(chain, withPrefix: true) != snapshot.ethereumChainId { return false }
                return body.method != .signTransaction || body.currentChainId != nil
            }
        case .solana(let body):
            return body.method == .connect || snapshot.solanaAccount?.normalizedAddress == body.publicKey
        case .unknown:
            return true
        }
    }

    private func bind(_ request: SafariRequest, data: Data, authority: ExtensionBridge.AuthoritySnapshot) -> (request: SafariRequest, data: Data)? {
        if request.provider != .unknown && request.authority == authority.version {
            var bound = request
            bound.authorizedAccount = request.provider == .ethereum ? authority.ethereumAccount : authority.solanaAccount
            return (bound, data)
        }
        var raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        raw?["authority"] = authority.version.json
        if case .unknown = request.body {
            var configurations = [[String: Any]]()
            configurations.append([
                "provider": "ethereum",
                "results": authority.ethereumAccount.map { [$0.normalizedAddress] } ?? [],
                "chainId": authority.ethereumChainId,
            ])
            if let account = authority.solanaAccount {
                configurations.append(["provider": "solana", "publicKey": account.normalizedAddress])
            }
            raw?["body"] = ["latestConfigurations": configurations]
        }
        guard let raw, let data = ExtensionBridge.payloadData(raw, options: [.sortedKeys]),
              var bound = parseRequest(raw) else { return nil }
        switch request.body {
        case .ethereum:
            bound.authorizedAccount = authority.ethereumAccount
        case .solana:
            bound.authorizedAccount = authority.solanaAccount
        case .unknown:
            bound.connectedAccounts = [authority.ethereumAccount, authority.solanaAccount].compactMap { $0 }
        }
        return (bound, data)
    }

    private func invalidateStaleRequests(
        in profile: inout ValidatedProfile,
        configurationKey: String,
        excluding: ExtensionBridge.Handle?,
        now: Date
    ) -> Bool {
        for index in profile.state.records.indices {
            let record = profile.state.records[index]
            guard record.configurationKey == configurationKey, record.handle != excluding else { continue }
            switch record.state {
            case .pending, .claimed:
                guard !authorityIsCurrent(record, in: profile.state) else { continue }
                guard let request = profile.request(for: record),
                      let response = boundedResponseData(ResponseToExtension(
                        for: request, payload: .error(.init(message: Strings.providerNotReady, code: 4100))
                      ), request: request) else { return false }
                profile.complete(at: index, response: response, date: now)
            case .broadcastPrepared, .completed:
                break
            }
        }
        return true
    }

    private func applyAuthorityEffect(
        _ response: ResponseToExtension,
        record: Record,
        profile: inout ValidatedProfile,
        now: Date
    ) -> Bool {
        guard let mutation = response.mutation else { return response.approvedAccounts.isEmpty }
        guard var origin = profile.state.origins[record.configurationKey] else { return false }
        switch mutation {
        case .accounts(let updates):
            guard let request = profile.request(for: record) else { return false }
            switch request.body {
            case .ethereum(let body):
                guard body.method == .requestAccounts, updates.count == 1,
                      updates.first?.provider == .ethereum else { return false }
            case .solana(let body):
                guard body.method == .connect, updates.count == 1,
                      updates.first?.provider == .solana else { return false }
            case .unknown:
                break
            }
            guard Set(updates.map(\.provider)).count == updates.count,
                  response.approvedAccounts.allSatisfy(\.isValid),
                  Set(response.approvedAccounts.map(\.coin)).count == response.approvedAccounts.count else { return false }
            var matched = Set<WalletAccountDescriptor>()
            for update in updates {
                guard let revision = nextRevision(in: &profile.state) else { return false }
                switch update {
                case .ethereum(let address, let chainId):
                    guard let account = response.approvedAccounts.first(where: {
                        $0.coin == .ethereum && $0.normalizedAddress == WalletCoin.ethereum.normalizedAddress(address)
                    }), canonicalChainID(chainId) else { return false }
                    origin.ethereumAccount = account
                    origin.ethereumChainId = chainId
                    origin.revisions = revisions(ethereum: revision, solana: origin.revisions.solana)
                    matched.insert(account)
                case .solana(let publicKey):
                    guard let account = response.approvedAccounts.first(where: {
                        $0.coin == .solana && $0.normalizedAddress == publicKey
                    }) else { return false }
                    origin.solanaAccount = account
                    origin.revisions = revisions(ethereum: origin.revisions.ethereum, solana: revision)
                    matched.insert(account)
                case .disconnectEthereum:
                    origin.ethereumAccount = nil
                    origin.revisions = revisions(ethereum: revision, solana: origin.revisions.solana)
                case .disconnectSolana:
                    origin.solanaAccount = nil
                    origin.revisions = revisions(ethereum: origin.revisions.ethereum, solana: revision)
                }
            }
            guard matched == Set(response.approvedAccounts) else { return false }
        case .ethereumChain(let chainId):
            guard let request = profile.request(for: record), case .ethereum(let body) = request.body,
                  body.method == .addEthereumChain || body.method == .switchEthereumChain else { return false }
            guard response.approvedAccounts.isEmpty, canonicalChainID(chainId) else { return false }
            guard origin.ethereumChainId != chainId else { return true }
            guard let revision = nextRevision(in: &profile.state) else { return false }
            origin.ethereumChainId = chainId
            origin.revisions = revisions(ethereum: revision, solana: origin.revisions.solana)
        case .revokeSolana(let publicKey):
            guard response.approvedAccounts.isEmpty else { return false }
            guard origin.solanaAccount?.normalizedAddress == publicKey else { return true }
            guard let revision = nextRevision(in: &profile.state) else { return false }
            origin.solanaAccount = nil
            origin.revisions = revisions(ethereum: origin.revisions.ethereum, solana: revision)
        }
        profile.state.origins[record.configurationKey] = origin
        guard (try? Self.encode(profile.state.origins).count).map({ $0 <= Self.maximumAuthorityBytes }) == true else { return false }
        return invalidateStaleRequests(in: &profile, configurationKey: record.configurationKey, excluding: record.handle, now: now)
    }

    private func canonicalChainID(_ value: String) -> Bool {
        guard let id = Int(hexString: value), id > 0 else { return false }
        return String.hex(id, withPrefix: true) == value
    }

    func enqueue(
        ingress: ExtensionBridge.Ingress,
        profileIdentifier: UUID?
    ) -> ExtensionBridge.EnqueueResult {
        withLock(or: .unavailable) {
            let now = clock()
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: profileIdentifier,
                now: now,
                recover: true
            ) else { return .unavailable }

            if let existing = profile.state.records.first(where: {
                $0.enqueueAttempt == ingress.request.enqueueAttempt
            }) {
                guard existing.id == ingress.request.id,
                      existing.host == ingress.request.host,
                      existing.configurationKey == ingress.request.configurationKey,
                      existing.requestFingerprint == ingress.fingerprint else {
                    return .rejected
                }
                if ingress.replayOnly {
                    switch existing.state {
                    case .pending:
                        return .rejected
                    case .claimed:
                        return .unavailable
                    case .broadcastPrepared, .completed:
                        break
                    }
                }
                let approvalRequired: Bool
                if case .completed = existing.state {
                    approvalRequired = false
                } else {
                    approvalRequired = true
                }
                guard synchronizeProfileLocked(profileIdentifier) else { return .unavailable }
                return .accepted(
                    handle: existing.handle,
                    approvalRequired: approvalRequired,
                    authority: authoritySnapshot(profile.state, configurationKey: existing.configurationKey),
                    admissionKind: .replay,
                    nativeDeliveryNonce: existing.nativeDeliveryNonce
                )
            }

            guard !ingress.replayOnly else { return .rejected }

            switch ExtensionBridge.admissionDeadlineDisposition(
                ingress.request.admissionDeadline,
                now: now
            ) {
            case .admissible:
                break
            case .expired:
                return .expired
            case .invalid:
                return .rejected
            }

            guard persistProfileIdentityIfMissing(profile) else { return .unavailable }
            let currentAuthority = authoritySnapshot(profile.state, configurationKey: ingress.request.configurationKey)
            guard authorityMatches(ingress.authority, current: currentAuthority.version,
                                   provider: ingress.request.provider, requestName: ingress.request.name),
                  requestIsAuthorized(ingress.request, by: currentAuthority) else {
                return .unauthorized(currentAuthority)
            }
            guard pinOrigin(in: &profile.state, configurationKey: ingress.request.configurationKey, now: now) else {
                return .unavailable
            }
            let isManualSwitchRequest = ingress.request.name == "switchAccount" &&
                ingress.request.provider == .unknown
            if isManualSwitchRequest,
               let existing = profile.state.records.first(where: { record in
                   record.configurationKey == ingress.request.configurationKey &&
                       !record.responseAcknowledged && isManualSwitch(record, in: profile)
               }) {
                guard synchronizeProfileLocked(profileIdentifier) else { return .unavailable }
                return .accepted(
                    handle: existing.handle,
                    approvalRequired: existing.state.isActive,
                    authority: authoritySnapshot(profile.state, configurationKey: existing.configurationKey),
                    admissionKind: .coalesced,
                    nativeDeliveryNonce: existing.nativeDeliveryNonce
                )
            }

            let manualSwitches = isManualSwitchRequest ? profile.state.records.filter {
                !$0.responseAcknowledged && isManualSwitch($0, in: profile)
            }.map(manualSwitchRequest) : []
            if isManualSwitchRequest, manualSwitches.count >= ExtensionBridge.maximumRequests {
                return .manualSwitchCapacityReached
            }

            let active = profile.state.records.filter(\.state.isActive)
            guard active.count < ExtensionBridge.maximumRequests,
                  active.filter({
                      $0.configurationKey == ingress.request.configurationKey
                  }).count <
                    ExtensionBridge.maximumRequestsPerHost,
                  let requestToken = uniqueToken(in: profile.state.records),
                  let nativeDeliveryNonceValue = uniqueToken(
                    in: profile.state.records,
                    excluding: requestToken
                  ) else {
                return .rejected
            }

            guard let boundRequest = bind(ingress.request, data: ingress.canonicalData, authority: currentAuthority),
                  boundRequest.data.count <= ExtensionBridge.maximumPayloadBytes else { return .rejected }
            let boundData = boundRequest.data

            var record = Record(
                id: ingress.request.id,
                profileIdentifier: profileIdentifier,
                enqueueAttempt: ingress.request.enqueueAttempt,
                requestToken: requestToken,
                host: ingress.request.host,
                configurationKey: ingress.request.configurationKey,
                requestFingerprint: ingress.fingerprint,
                authority: currentAuthority.version,
                authorizedAccount: boundRequest.request.authorizedAccount,
                executionDeadline: nil,
                admissionCreatedAt: now,
                createdAt: now,
                state: .pending(request: boundData, approval: .unowned),
                nativeDeliveryNonce: .init(value: nativeDeliveryNonceValue)
            )
            if case .ethereum(let body) = boundRequest.request.body,
               body.method == .switchEthereumChain,
               let chainId = body.switchToChainId,
               String.hex(chainId, withPrefix: true) == currentAuthority.ethereumChainId {
                guard let response = boundedResponseData(
                    ResponseToExtension(for: boundRequest.request, payload: .result(.null)),
                    request: boundRequest.request
                ) else { return .unavailable }
                record.complete(response: response, at: now)
            }
            if isManualSwitchRequest,
               !manualSwitchRequestsFit(manualSwitches + [manualSwitchRequest(record)]) {
                return .manualSwitchCapacityReached
            }
            guard let retiredHandles = makeRoomForAdmission(
                record,
                in: &profile.state.records,
                now: now
            ) else { return .rejected }
            profile.state.records.append(record)
            if record.state.isActive {
                profile.parsedRequests[record.handle] = boundRequest.request
            }
            for handle in retiredHandles {
                profile.parsedRequests.removeValue(forKey: handle)
            }
            reclaimAuthority(in: &profile.state, now: now)
            guard writeProfileLocked(profile, failureRecovery: .readBack) else {
                return .unavailable
            }
            for handle in retiredHandles {
                removeOperationLockLocked(handle: handle)

            }
            return .accepted(
                handle: record.handle,
                approvalRequired: record.state.isActive,
                authority: authoritySnapshot(profile.state, configurationKey: record.configurationKey),
                admissionKind: .new,
                nativeDeliveryNonce: record.nativeDeliveryNonce
            )
        }
    }

    func list(profileIdentifier: UUID?) -> ExtensionBridge.SnapshotsResult {
        return withLock(or: .unavailable) {
            let now = clock()
            guard prepareDirectoriesLocked() else { return .unavailable }
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: profileIdentifier,
                now: now,
                recover: true
            ) else { return .unavailable }
            let completedCount = max(
                0,
                ExtensionBridge.maximumRetainedRequests -
                    profile.state.records.filter(\.state.isActive).count
            )
            let completedHandles = Set(profile.state.records.filter {
                !$0.state.isActive && !$0.responseAcknowledged
            }.prefix(completedCount).map(\.handle))
            var snapshots = [ExtensionBridge.Handle: ExtensionBridge.Snapshot]()
            for item in profile.state.records.enumerated() {
                guard item.element.state.isActive ||
                    completedHandles.contains(item.element.handle) else { continue }
                guard let snapshot = snapshot(
                    item.element,
                    request: profile.request(for: item.element),
                    sequence: item.offset
                ) else { return .unavailable }
                snapshots[item.element.handle] = snapshot
            }
            return .available(snapshots)
        }
    }

    func load(handle: ExtensionBridge.Handle) -> ExtensionBridge.SnapshotResult {
        withLock(or: .unavailable) {
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .unavailable }
            guard let index = profile.state.records.firstIndex(where: {
                $0.handle == handle
            }) else {
                return .missing
            }
            guard let snapshot = snapshot(
                profile.state.records[index],
                request: profile.request(for: profile.state.records[index]),
                sequence: index
            ) else { return .unavailable }
            return .found(snapshot)
        }
    }

    func listManualSwitchRequests(
        profileIdentifier: UUID?
    ) -> ExtensionBridge.ManualSwitchRequestsResult {
        guard case .state(let profile) = readProfileObservational(
            profileIdentifier: profileIdentifier
        ) else { return .unavailable }
        let requests = profile.state.records.filter {
            !$0.responseAcknowledged && isManualSwitch($0, in: profile)
        }.sorted {
            $0.admissionCreatedAt == $1.admissionCreatedAt
                ? $0.handle.requestToken < $1.handle.requestToken
                : $0.admissionCreatedAt < $1.admissionCreatedAt
        }.map(manualSwitchRequest)
        guard manualSwitchRequestsFit(requests) else { return .unavailable }
        return .available(requests)
    }

    func responseStatus(
        handle: ExtensionBridge.Handle,
        configurationKey: String,
        manualOnly: Bool = false
    ) -> ExtensionBridge.ResponseStatusResult {
        guard case .state(let profile) = readProfileObservational(
            profileIdentifier: handle.profileIdentifier
        ) else { return .unavailable }
        guard let record = profile.state.records.first(where: {
            $0.handle == handle && $0.configurationKey == configurationKey
        }), !manualOnly || (!record.responseAcknowledged && isManualSwitch(record, in: profile)) else {
            return .missing
        }
        if case .completed = record.state { return .ready }
        return .pending
    }

    private func manualSwitchRequestsFit(
        _ requests: [ExtensionBridge.ManualSwitchRequest]
    ) -> Bool {
        guard requests.count <= ExtensionBridge.maximumRequests else { return false }
        let descriptors = requests.map { request in
            var descriptor = request.json
            descriptor["state"] = ExtensionBridge.ManualSwitchRequestState.completed.rawValue
            return descriptor
        }
        return ExtensionBridge.payloadData([
            "id": Int.min,
            "requests": descriptors,
        ]).map { $0.count <= ExtensionBridge.maximumManualSwitchResponseBytes } ?? false
    }

    func loadManualSwitch(
        handle: ExtensionBridge.Handle,
        configurationKey: String
    ) -> ExtensionBridge.SnapshotResult {
        withLock(or: .unavailable) {
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .unavailable }
            guard let index = profile.state.records.firstIndex(where: {
                $0.handle == handle && $0.configurationKey == configurationKey &&
                    !$0.responseAcknowledged && isManualSwitch($0, in: profile)
            }) else { return .missing }
            guard let snapshot = snapshot(
                profile.state.records[index],
                request: profile.request(for: profile.state.records[index]),
                sequence: index
            ) else { return .unavailable }
            return .found(snapshot)
        }
    }

    private func isManualSwitch(_ record: Record, in profile: ValidatedProfile) -> Bool {
        if let request = profile.request(for: record) {
            return request.name == "switchAccount" && request.provider == .unknown
        }
        return record.state.responseData.flatMap {
            responseJSON($0, id: record.id)
        }?["name"] as? String == "switchAccount"
    }

    private func manualSwitchRequest(_ record: Record) -> ExtensionBridge.ManualSwitchRequest {
        let state: ExtensionBridge.ManualSwitchRequestState
        switch record.state {
        case .completed:
            state = .completed
        case .claimed, .broadcastPrepared:
            state = .approved
        case .pending:
            state = .pending
        }
        return .init(
            handle: record.handle,
            host: record.host,
            configurationKey: record.configurationKey,
            revisions: record.revisions,
            state: state
        )
    }

    func claim(
        handle: ExtensionBridge.Handle
    ) -> ExtensionBridge.ApprovalClaimResult {
        withLock(or: .unavailable) {
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .unavailable }
            guard let index = profile.state.records.firstIndex(where: { $0.handle == handle }) else {
                return .missing
            }
            switch profile.state.records[index].state {
            case .pending(let request, let approval):
                guard case .unowned = approval else {
                    return .executing
                }
                guard let lease = acquireOperationLeaseLocked(handle: handle),
                      let claimID = nextID(excluding: handle.token.value) else {
                    return .unavailable
                }
                guard authorityIsCurrent(profile.state.records[index], in: profile.state),
                      let parsed = profile.request(for: profile.state.records[index]) else {
                    lease.release()
                    return .missing
                }
                let deadline = min(clock().addingTimeInterval(Self.executionLifetime), parsed.admissionDeadline)
                profile.state.records[index].executionDeadline = deadline
                profile.state.records[index].state = .claimed(
                    claimID: claimID,
                    request: request,
                    approval: .ordinary
                )
                guard writeProfileLocked(profile) else {
                    lease.release()
                    return .unavailable
                }
                return .claimed(.init(
                    handle: handle,
                    value: claimID,
                    lease: lease, executionDeadline: deadline
                ))
            case .claimed, .broadcastPrepared:
                return .executing
            case .completed:
                return .responded
            }
        }
    }

    func recordNativeDeliveryReceipt(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        owner: ExtensionBridge.NativeDeliveryOwner
    ) -> ExtensionBridge.StoreMutationResult {
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: nativeDeliveryNonce,
            owner: owner
        )
        return withLock(or: .retryablePersistenceFailure) {
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: {
                $0.handle == handle
            }), case .pending(let request, _) = profile.state.records[index].state,
                  profile.state.records[index].nativeDeliveryNonce ==
                    nativeDeliveryNonce else {
                return .ownershipLost
            }
            if let existing = profile.state.records[index].nativeDeliveryReceipt {
                guard existing == receipt else { return .ownershipLost }
                return synchronizedMutationResultLocked(handle.profileIdentifier)
            }
            profile.state.records[index].state = .pending(
                request: request,
                approval: .delivered(receipt)
            )
            return writeProfileLocked(profile, failureRecovery: .readBack)
                ? .persisted
                : .retryablePersistenceFailure
        }
    }

    func clearNativeDeliveryReceipt(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID
    ) -> ExtensionBridge.StoreMutationResult {
        return withLock(or: .retryablePersistenceFailure) {
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: {
                $0.handle == handle
            }), case .pending(let request, _) = profile.state.records[index].state,
                  profile.state.records[index].nativeDeliveryNonce ==
                    nativeDeliveryNonce else {
                return .ownershipLost
            }
            guard let existing = profile.state.records[index].nativeDeliveryReceipt else {
                return synchronizedMutationResultLocked(handle.profileIdentifier)
            }
            guard existing.nativeDeliveryNonce == nativeDeliveryNonce,
                  existing.owner.runtimeInstanceIdentifier ==
                    runtimeInstanceIdentifier else {
                return .ownershipLost
            }
            profile.state.records[index].state = .pending(request: request, approval: .unowned)
            return writeProfileLocked(profile, failureRecovery: .readBack)
                ? .persisted
                : .retryablePersistenceFailure
        }
    }

    func interruptNativeApproval(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID
    ) -> ExtensionBridge.NativeInterruptionResult {
        withLock(or: .retryablePersistenceFailure) {
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: false
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: { $0.handle == handle }) else {
                return .ownershipLost
            }
            if case .completed(_, let response, _) = profile.state.records[index].state {
                guard synchronizeProfileLocked(handle.profileIdentifier) else {
                    return .retryablePersistenceFailure
                }
                if let json = responseJSON(response, id: handle.id),
                   let terminal = ResponseToExtension(json: json),
                   case .error(let error) = terminal.payload,
                   error == .approvalInterrupted {
                    return .interrupted
                }
                return .responseReady
            }
            guard profile.state.records[index].nativeDeliveryReceipt?.matches(
                nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtimeInstanceIdentifier
            ) == true else { return .ownershipLost }
            let hasBroadcastCheckpoint: Bool
            if case .broadcastPrepared = profile.state.records[index].state {
                hasBroadcastCheckpoint = true
            } else {
                hasBroadcastCheckpoint = false
            }
            guard interruptNativeRecord(in: &profile, at: index, now: clock()),
                  writeProfileLocked(profile, failureRecovery: .readBack) else {
                return .retryablePersistenceFailure
            }
            removeOperationLockLocked(handle: handle)

            return hasBroadcastCheckpoint ? .responseReady : .interrupted
        }
    }

    private func interruptionResponseData(for request: SafariRequest?) -> Data? {
        guard let request else { return nil }
        return boundedResponseData(
            ResponseToExtension(for: request, payload: .error(.approvalInterrupted)),
            request: request
        )
    }

    private func interruptNativeRecord(
        in profile: inout ValidatedProfile,
        at index: Int,
        now: Date
    ) -> Bool {
        let record = profile.state.records[index]
        let response: Data
        switch record.state {
        case .completed:
            return true
        case .broadcastPrepared(_, _, let recoveryResponse, _):
            response = recoveryResponse
        case .pending, .claimed:
            guard let data = interruptionResponseData(for: profile.request(for: record)) else {
                return false
            }
            response = data
        }
        profile.complete(at: index, response: response, date: now)
        return true
    }

    func claimNativeExecution(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        approvedAt: Date
    ) -> ExtensionBridge.NativeExecutionClaimResult {
        withLock(or: .unavailable) {
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .unavailable }
            guard let index = profile.state.records.firstIndex(where: {
                $0.handle == handle
            }) else { return .missing }
            switch profile.state.records[index].state {
            case .pending(let request, let pendingApproval):
                guard case .delivered(let receipt) = pendingApproval,
                      receipt.matches(
                          nativeDeliveryNonce: nativeDeliveryNonce,
                          runtimeInstanceIdentifier: runtimeInstanceIdentifier
                      ) else { return .ownershipLost }
                let now = clock()
                guard approvedAt.timeIntervalSince1970.isFinite,
                      approvedAt >= profile.state.records[index].createdAt,
                      approvedAt <= now,
                      authorityIsCurrent(profile.state.records[index], in: profile.state) else {
                    return .ownershipLost
                }
                let parsedRequest: SafariRequest
                switch transitionExpiredPending(in: &profile, at: index, now: now) {
                case .active(let request):
                    parsedRequest = request
                case .expired:
                    return writeProfileLocked(profile, failureRecovery: .readBack)
                        ? .ownershipLost
                        : .unavailable
                case .unavailable:
                    return .unavailable
                }
                let approval = Record.NativeApproval(approvedAt: approvedAt, receipt: receipt)
                let executionContext = ExtensionBridge.NativeExecutionContext(
                    attemptID: token(),
                    revisions: profile.state.records[index].revisions,
                    observedAt: now,
                    executionDeadline: min(
                        now.addingTimeInterval(Self.executionLifetime),
                        parsedRequest.admissionDeadline
                    ),
                    fenceToken: token()
                )
                guard let claimID = nextID(excluding: handle.token.value),
                      let lease = acquireOperationLeaseLocked(handle: handle) else {
                    return .unavailable
                }
                profile.state.records[index].state = .claimed(
                    claimID: claimID,
                    request: request,
                    approval: .native(approval, context: executionContext)
                )
                guard writeProfileLocked(profile) else {
                    lease.release()
                    return .unavailable
                }
                let claim = ExtensionBridge.ApprovalClaim(
                    handle: handle,
                    value: claimID,
                    lease: lease,
                    executionDeadline: executionContext.executionDeadline
                )
                return .claimed(.init(
                    approvalClaim: claim,
                    approvedAt: approval.approvedAt,
                    executionContext: executionContext
                ))
            case .claimed, .broadcastPrepared:
                return .executing
            case .completed:
                return .responded
            }
        }
    }

    func release(
        claim: ExtensionBridge.ApprovalClaim
    ) -> ExtensionBridge.StoreMutationResult {
        withLock(or: .retryablePersistenceFailure) {
            let now = clock()
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: claim.handle.profileIdentifier,
                now: now,
                recover: false
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: {
                $0.handle == claim.handle
            }), case .claimed(let claimID, _, _) = profile.state.records[index].state,
                  claim.matches(handle: claim.handle, value: claimID) else {
                return .ownershipLost
            }
            return abandonClaimLocked(
                in: &profile,
                at: index,
                now: now,
                releaseLease: claim.releaseLease
            )
        }
    }

    func complete(
        handle: ExtensionBridge.Handle,
        response: ResponseToExtension
    ) -> ExtensionBridge.StoreMutationResult {
        finish(
            handle: handle,
            expectedReceipt: nil,
            response: response
        )
    }

    func completeNativeDelivery(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        response: ResponseToExtension
    ) -> ExtensionBridge.StoreMutationResult {
        finish(
            handle: handle,
            expectedReceipt: .init(
                nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtimeInstanceIdentifier
            ),
            response: response
        )
    }

    func reject(
        handle: ExtensionBridge.Handle
    ) -> ExtensionBridge.StoreMutationResult {
        reject(handle: handle, expectedReceipt: nil)
    }

    func rejectNativeDelivery(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID
    ) -> ExtensionBridge.StoreMutationResult {
        reject(
            handle: handle,
            expectedReceipt: .init(
                nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtimeInstanceIdentifier
            )
        )
    }

    private func reject(
        handle: ExtensionBridge.Handle,
        expectedReceipt: ReceiptIdentity?
    ) -> ExtensionBridge.StoreMutationResult {
        withLock(or: .retryablePersistenceFailure) {
            let now = clock()
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: now,
                recover: true
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: { $0.handle == handle }),
                  let request = profile.request(for: profile.state.records[index]),
                  case .pending = profile.state.records[index].state,
                  receiptMatches(
                    profile.state.records[index].nativeDeliveryReceipt,
                    expected: expectedReceipt
                  ) else {
                return .ownershipLost
            }
            let response = ResponseToExtension(
                for: request,
                payload: .error(.userRejected)
            )
            guard let data = boundedResponseData(response, request: request) else {
                return .retryablePersistenceFailure
            }
            profile.complete(at: index, response: data, date: now)
            return writeProfileLocked(profile, failureRecovery: .readBack)
                ? .persisted
                : .retryablePersistenceFailure
        }
    }

    func begin(
        claim: ExtensionBridge.ApprovalClaim
    ) -> ExtensionBridge.BeginExecutionResult {
        withLock(or: .retryablePersistenceFailure) {
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: claim.handle.profileIdentifier,
                now: clock(),
                recover: false
            ) else { return .retryablePersistenceFailure }
            guard let record = profile.state.records.first(where: {
                $0.handle == claim.handle
            }), case .claimed(let claimID, _, _) = record.state,
                  claim.matches(handle: claim.handle, value: claimID),
                  authorityIsCurrent(record, in: profile.state),
                  executionDeadlineIsCurrent(record.nativeExecutionContext?.executionDeadline ?? record.executionDeadline, now: clock()),
                  let lease = claim.lease,
                  lease.consume() else { return .ownershipLost }
            return .began(.init(
                handle: claim.handle,
                value: claimID,
                lease: lease
            ))
        }
    }

    func prepareBroadcast(
        permit: ExtensionBridge.ExecutionPermit,
        recoveryResponse: ResponseToExtension,
        authority: ExtensionBridge.ExecutionAuthority
    ) -> ExtensionBridge.StoreMutationResult {
        withLock(or: .retryablePersistenceFailure) {
            let readTime = clock()
            guard recoveryResponse.id == permit.handle.id,
                  let responseData = exactResponseData(recoveryResponse) else {
                return .ownershipLost
            }
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: permit.handle.profileIdentifier,
                now: readTime,
                recover: false
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: {
                $0.handle == permit.handle
            }) else { return .ownershipLost }
            switch profile.state.records[index].state {
            case .claimed(let claimID, let request, let approval):
                let authorizationTime = clock()
                guard permit.matches(handle: permit.handle, value: claimID),
                      permit.lease != nil,
                      authorityIsCurrent(profile.state.records[index], in: profile.state),
                      executionAuthorityAuthorizesLocked(
                          record: profile.state.records[index],
                          authority: authority,
                          now: authorizationTime
                      ) else { return .ownershipLost }
                profile.state.records[index].state = .broadcastPrepared(
                    claimID: claimID,
                    request: request,
                    recoveryResponse: responseData,
                    approval: approval.broadcast
                )
                return writeProfileLocked(profile)
                    ? .persisted
                    : .retryablePersistenceFailure
            case .broadcastPrepared(let claimID, _, let existing, _):
                guard permit.matches(handle: permit.handle, value: claimID) else {
                    return .ownershipLost
                }
                guard existing == responseData else { return .ownershipLost }
                return synchronizedMutationResultLocked(permit.handle.profileIdentifier)
            case .pending, .completed:
                return .ownershipLost
            }
        }
    }

    func complete(
        permit: ExtensionBridge.ExecutionPermit,
        response: ResponseToExtension,
        authority: ExtensionBridge.ExecutionAuthority
    ) -> ExtensionBridge.StoreMutationResult {
        withLock(or: .retryablePersistenceFailure) {
            let readTime = clock()
            guard response.id == permit.handle.id else { return .ownershipLost }
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: permit.handle.profileIdentifier,
                now: readTime,
                recover: false
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: {
                $0.handle == permit.handle
            }) else { return .ownershipLost }
            let claimID: UUID
            let recoveryResponseData: Data?
            switch profile.state.records[index].state {
            case .claimed(let value, _, _):
                claimID = value
                recoveryResponseData = nil
            case .broadcastPrepared(let value, _, let recoveryResponse, _):
                claimID = value
                recoveryResponseData = recoveryResponse
            case .completed:
                guard synchronizeProfileLocked(permit.handle.profileIdentifier) else {
                    return .retryablePersistenceFailure
                }
                permit.releaseLease()
                return .persisted
            case .pending:
                return .ownershipLost
            }
            let authorizationTime = clock()
            guard permit.matches(handle: permit.handle, value: claimID),
                  (recoveryResponseData != nil || authorityIsCurrent(profile.state.records[index], in: profile.state)),
                  executionAuthorityAuthorizesLocked(
                      record: profile.state.records[index],
                      authority: authority,
                      now: authorizationTime
                  ),
                  let request = profile.request(for: profile.state.records[index]),
                  let responseData = boundedResponseData(
                      response,
                      request: request,
                      recoveryResponseData: recoveryResponseData
                  ) else {
                return .ownershipLost
            }
            let completing = profile.state.records[index]
            if recoveryResponseData == nil {
                guard applyAuthorityEffect(response, record: completing, profile: &profile, now: authorizationTime) else { return .ownershipLost }
            }
            profile.complete(at: index, response: responseData, date: authorizationTime)
            guard writeProfileLocked(profile) else {
                return .retryablePersistenceFailure
            }
            permit.releaseLease()
            removeOperationLockLocked(handle: permit.handle)

            return .persisted
        }
    }

    func rollback(
        permit: ExtensionBridge.ExecutionPermit
    ) -> ExtensionBridge.StoreMutationResult {
        withLock(or: .retryablePersistenceFailure) {
            let now = clock()
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: permit.handle.profileIdentifier,
                now: now,
                recover: false
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: {
                $0.handle == permit.handle
            }), case .claimed(let claimID, _, _) =
                    profile.state.records[index].state,
                  permit.matches(handle: permit.handle, value: claimID),
                  permit.lease != nil else { return .ownershipLost }
            return abandonClaimLocked(
                in: &profile,
                at: index,
                now: now,
                releaseLease: permit.releaseLease
            )
        }
    }

    private func abandonClaimLocked(
        in profile: inout ValidatedProfile,
        at index: Int,
        now: Date,
        releaseLease: () -> Void
    ) -> ExtensionBridge.StoreMutationResult {
        let handle = profile.state.records[index].handle
        let result: ExtensionBridge.StoreMutationResult
        if profile.state.records[index].nativeApproval != nil {
            guard interruptNativeRecord(in: &profile, at: index, now: now),
                  writeProfileLocked(profile, failureRecovery: .readBack) else {
                return .retryablePersistenceFailure
            }
            result = .persisted
        } else {
            profile.state.records[index].restorePendingClaim()
            switch transitionExpiredPending(
                in: &profile,
                at: index,
                now: now
            ) {
            case .active:
                result = .persisted
            case .expired:
                result = .ownershipLost
            case .unavailable:
                return .retryablePersistenceFailure
            }
            guard writeProfileLocked(profile) else {
                return .retryablePersistenceFailure
            }
        }
        releaseLease()
        removeOperationLockLocked(handle: handle)

        return result
    }

    func prepareResponseDelivery(
        handle: ExtensionBridge.Handle,
        configurationKey: String
    ) -> ExtensionBridge.ResponseReadResult {
        withLock(or: .unavailable) {
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .unavailable }
            guard let record = profile.state.records.first(where: { $0.handle == handle }),
                  record.configurationKey == configurationKey else { return .missing }
            switch record.state {
            case .pending, .claimed, .broadcastPrepared:
                return .pending
            case .completed(_, let responseData, _):
                guard let response = responseJSON(responseData, id: handle.id),
                      synchronizeProfileLocked(handle.profileIdentifier) else {
                    return .unavailable
                }
                return .response(["id": handle.id, "response": response,
                    "state": authoritySnapshot(profile.state, configurationKey: configurationKey).json])
            }
        }
    }

    func acknowledgeResponse(
        handle: ExtensionBridge.Handle,
        configurationKey: String
    ) -> ExtensionBridge.StoreMutationResult {
        withLock(or: .retryablePersistenceFailure) {
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: {
                $0.handle == handle && $0.configurationKey == configurationKey
            }) else { return .ownershipLost }
            guard case .completed(let since, let response, let acknowledged) =
                    profile.state.records[index].state else {
                return .retryablePersistenceFailure
            }
            if acknowledged {
                return synchronizedMutationResultLocked(handle.profileIdentifier)
            }
            profile.state.records[index].state = .completed(
                since: since,
                response: response,
                acknowledged: true
            )
            return writeProfileLocked(profile, failureRecovery: .readBack)
                ? .persisted
                : .retryablePersistenceFailure
        }
    }

    private func finish(
        handle: ExtensionBridge.Handle,
        expectedReceipt: ReceiptIdentity?,
        response: ResponseToExtension
    ) -> ExtensionBridge.StoreMutationResult {
        withLock(or: .retryablePersistenceFailure) {
            let now = clock()
            guard response.id == handle.id else { return .ownershipLost }
            guard case .state(var profile) = readProfileLocked(
                    profileIdentifier: handle.profileIdentifier,
                    now: now,
                    recover: false
                  ) else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: { $0.handle == handle }) else {
                return .ownershipLost
            }
            guard case .pending = profile.state.records[index].state,
                  receiptMatches(
                    profile.state.records[index].nativeDeliveryReceipt,
                    expected: expectedReceipt
                  ) else {
                return .ownershipLost
            }
            let request: SafariRequest
            switch transitionExpiredPending(
                in: &profile,
                at: index,
                now: now
            ) {
            case .active(let activeRequest):
                request = activeRequest
            case .expired:
                return writeProfileLocked(profile)
                    ? .ownershipLost
                    : .retryablePersistenceFailure
            case .unavailable:
                return .retryablePersistenceFailure
            }
            guard let responseData = boundedResponseData(response, request: request) else {
                return .retryablePersistenceFailure
            }
            guard authorityIsCurrent(profile.state.records[index], in: profile.state),
                  applyAuthorityEffect(response, record: profile.state.records[index], profile: &profile, now: now) else { return .ownershipLost }
            profile.complete(at: index, response: responseData, date: now)
            return writeProfileLocked(profile, failureRecovery: .readBack)
                ? .persisted
                : .retryablePersistenceFailure
        }
    }

    private func readProfileLocked(
        profileIdentifier: UUID?,
        now: Date,
        recover: Bool
    ) -> ProfileRead {
        guard prepareDirectoriesLocked() else { return .unavailable }
        return readProfileFileLocked(
            at: profileURL(profileIdentifier),
            profileIdentifier: profileIdentifier,
            now: now,
            recover: recover
        )
    }

    private func readProfileObservational(
        profileIdentifier: UUID?
    ) -> ProfileRead {
        guard let rootURL, let storeLock else { return .unavailable }
        switch directoryStatus(at: rootURL) {
        case .missing:
            return .state(emptyProfile(profileIdentifier))
        case .directory:
            break
        case .unsafe, .unavailable:
            return .unavailable
        }
        let lockURL = rootURL.appendingPathComponent("bridge-v8.lock")
        switch regularFileStatusLocked(at: lockURL) {
        case .missing:
            guard directoryStatus(at: profileDirectoryURL) == .missing else {
                return .unavailable
            }
            return .state(emptyProfile(profileIdentifier))
        case .regular:
            break
        case .unsafe, .unavailable:
            return .unavailable
        }
        guard (try? storeLock.tryAcquireExisting()) == true else { return .unavailable }
        defer { storeLock.release() }
        switch directoryStatus(at: profileDirectoryURL) {
        case .missing:
            return .state(emptyProfile(profileIdentifier))
        case .directory:
            break
        case .unsafe, .unavailable:
            return .unavailable
        }
        return readProfileFileLocked(
            at: profileURL(profileIdentifier),
            profileIdentifier: profileIdentifier,
            now: clock(),
            recover: false,
            normalizeDates: false
        )
    }

    private func readProfileFileLocked(
        at url: URL,
        profileIdentifier: UUID?,
        now: Date,
        recover: Bool,
        normalizeDates: Bool = true
    ) -> ProfileRead {
        let data: Data
        switch readProfileDataLocked(at: url) {
        case .missing:
            return .state(emptyProfile(profileIdentifier))
        case .data(let storedData):
            data = storedData
        case .corrupt:
            return .corrupt
        case .unavailable:
            return .unavailable
        }
        guard var state = try? PropertyListDecoder().decode(ProfileState.self, from: data),
              state.authoritySequence >= 0, state.authoritySequence <= Self.maximumRevision else { return .corrupt }
        for record in state.records {
            switch record.state {
            case .pending, .claimed:
                if authorityStatus(record, in: state) == .inconsistentGrant {
                    state.invalidOrigins.insert(record.configurationKey)
                }
            case .broadcastPrepared, .completed:
                break
            }
        }
        var profile: ValidatedProfile
        if let validated = validateAndParse(state, expectedIdentifier: profileIdentifier) {
            profile = validated
        } else if recover, let repaired = repairAuthority(state, expectedIdentifier: profileIdentifier, now: now) {
            guard writeProfileLocked(repaired, failureRecovery: .readBack) else { return .unavailable }
            profile = repaired
        } else {
            return .corrupt
        }
        let normalizedDates = normalizeDates && normalizeFutureDates(in: &profile.state, now: now)
        guard recover else { return .state(profile) }
        var changed = normalizedDates
        var locksToRemove = [ExtensionBridge.Handle]()
        var kept = [Record]()
        for var record in profile.state.records {
            switch record.state {
            case .claimed:
                switch operationLockStatusLocked(handle: record.handle) {
                case .held, .unsafe, .unavailable:
                    break
                case .unlocked:
                    if record.nativeApproval != nil {
                        guard let response = interruptionResponseData(for: profile.request(for: record)) else {
                            return .unavailable
                        }
                        record.complete(response: response, at: now)
                        profile.parsedRequests.removeValue(forKey: record.handle)
                    } else {
                        record.restorePendingClaim()
                    }
                    changed = true
                    locksToRemove.append(record.handle)
                }
            case .broadcastPrepared(_, _, let recoveryResponse, _):
                switch operationLockStatusLocked(handle: record.handle) {
                case .held, .unsafe, .unavailable:
                    break
                case .unlocked:
                    record.complete(response: recoveryResponse, at: now)
                    profile.parsedRequests.removeValue(forKey: record.handle)
                    changed = true
                    locksToRemove.append(record.handle)
                }
            case .pending, .completed:
                break
            }
            switch record.state {
            case .pending:
                let request = profile.request(for: record)
                switch transitionExpiredPending(
                    &record,
                    request: request,
                    now: now
                ) {
                case .active:
                    break
                case .expired:
                    profile.parsedRequests.removeValue(forKey: record.handle)
                    changed = true
                    if !locksToRemove.contains(record.handle) {
                        locksToRemove.append(record.handle)
                    }
                case .unavailable:
                    return .unavailable
                }
                kept.append(record)
            case .completed(let since, _, _):
                if now.timeIntervalSince(since) >= ExtensionBridge.responseExpiry,
                   canRetireAdmissionRecord(record, now: now) {
                    profile.parsedRequests.removeValue(forKey: record.handle)
                    changed = true
                    locksToRemove.append(record.handle)
                } else {
                    kept.append(record)
                }
            case .claimed, .broadcastPrepared:
                kept.append(record)
            }
        }
        profile.state.records = kept
        changed = reclaimAuthority(in: &profile.state, now: now) || changed
        guard changed else { return .state(profile) }
        guard writeProfileLocked(profile) else { return .unavailable }
        for handle in locksToRemove {
            removeOperationLockLocked(handle: handle)

        }
        return .state(profile)
    }

    func performMaintenance() {
        let candidates = discoverProfileCandidates()
        for candidate in candidates {
            let maintained = withLock(or: false) {
                guard prepareDirectoriesLocked() else { return false }
                _ = readProfileFileLocked(
                    at: candidate.url,
                    profileIdentifier: candidate.identity.identifier,
                    now: clock(),
                    recover: true
                )
                return true
            }
            if !maintained { return }
        }
    }

    func performMaintenance(profileIdentifier: UUID?) {
        _ = withLock(or: false) {
            guard prepareDirectoriesLocked() else { return false }
            _ = readProfileFileLocked(
                at: profileURL(profileIdentifier),
                profileIdentifier: profileIdentifier,
                now: clock(),
                recover: true
            )
            return true
        }
    }

    private func discoverProfileCandidates() -> [ProfileFileCandidate] {
        guard rootURL != nil else { return [] }
        do {
            let attributes = try fileManager.attributesOfItem(
                atPath: profileDirectoryURL.path
            )
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                return []
            }
            return try fileManager.contentsOfDirectory(
                at: profileDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).compactMap { url in
                guard let identity = profileFileIdentity(for: url) else { return nil }
                return ProfileFileCandidate(url: url, identity: identity)
            }
        } catch {
            return []
        }
    }

    private func expirationResponseData(for request: SafariRequest) -> Data? {
        boundedResponseData(
            ResponseToExtension(for: request, payload: .error(.userRejected)),
            request: request
        )
    }

    private func transitionExpiredPending(
        in profile: inout ValidatedProfile,
        at index: Int,
        now: Date
    ) -> PendingDeadlineTransition {
        let request = profile.request(for: profile.state.records[index])
        let transition = transitionExpiredPending(
            &profile.state.records[index],
            request: request,
            now: now
        )
        if case .expired = transition {
            profile.parsedRequests.removeValue(forKey: profile.state.records[index].handle)
        }
        return transition
    }

    private func transitionExpiredPending(
        _ record: inout Record,
        request: SafariRequest?,
        now: Date
    ) -> PendingDeadlineTransition {
        guard case .pending = record.state, let request else {
            return .unavailable
        }
        guard request.admissionDeadline <= now else {
            return .active(request)
        }
        guard let responseData = expirationResponseData(for: request) else {
            return .unavailable
        }
        record.complete(response: responseData, at: now)
        return .expired
    }

    private func validOrigin(_ origin: OriginState, sequence: Int) -> Bool {
        canonicalChainID(origin.ethereumChainId) &&
            origin.revisions.ethereum <= sequence && origin.revisions.solana <= sequence &&
            (origin.ethereumAccount.map { $0.isValid && $0.coin == .ethereum } ?? true) &&
            (origin.solanaAccount.map { $0.isValid && $0.coin == .solana } ?? true)
    }

    private func repairAuthority(
        _ stored: ProfileState,
        expectedIdentifier: UUID?,
        now: Date
    ) -> ValidatedProfile? {
        guard stored.schemaVersion == Self.profileSchemaVersion,
              stored.workflowVersion == ExtensionBridge.workflowVersion,
              stored.profileIdentifier == expectedIdentifier,
              stored.authoritySequence >= 0, stored.authoritySequence < Self.maximumRevision,
              stored.records.allSatisfy({
                  $0.revisions.ethereum <= stored.authoritySequence && $0.revisions.solana <= stored.authoritySequence
              }) else { return nil }
        let referencedOrigins = Set(stored.records.map(\.configurationKey) + stored.mutationReceipts.map(\.configurationKey))
        let invalidOrigins = stored.invalidOrigins
            .union(stored.origins.filter { !validOrigin($0.value, sequence: stored.authoritySequence) }.keys)
            .union(referencedOrigins.subtracting(stored.origins.keys))
        guard stored.invalidOriginsContainer || !invalidOrigins.isEmpty,
              invalidOrigins.allSatisfy(validConfigurationKey),
              Set(stored.origins.keys).union(invalidOrigins).count <= Self.maximumOrigins else { return nil }

        var state = stored
        guard let revision = nextRevision(in: &state) else { return nil }
        for key in invalidOrigins {
            state.origins[key] = OriginState(revisions: revisions(ethereum: revision, solana: revision))
        }
        state.invalidOrigins.removeAll()
        state.invalidOriginsContainer = false
        guard var profile = validateAndParse(state, expectedIdentifier: expectedIdentifier) else { return nil }
        for key in invalidOrigins {
            guard invalidateStaleRequests(in: &profile, configurationKey: key, excluding: nil, now: now) else { return nil }
        }
        return profile
    }

    private func validateAndParse(
        _ profile: ProfileState,
        expectedIdentifier: UUID?
    ) -> ValidatedProfile? {
        let active = profile.records.filter(\.state.isActive)
        guard profile.schemaVersion == Self.profileSchemaVersion,
              profile.workflowVersion == ExtensionBridge.workflowVersion,
              profile.profileIdentifier == expectedIdentifier,
              profile.invalidOrigins.isEmpty, !profile.invalidOriginsContainer,
              profile.authoritySequence >= 0, profile.authoritySequence <= Self.maximumRevision,
              profile.origins.count <= Self.maximumOrigins,
              (try? Self.encode(profile.origins).count).map({ $0 <= Self.maximumAuthorityBytes }) == true,
              profile.mutationReceipts.count <= Self.maximumMutationReceipts,
              Set(profile.mutationReceipts.map(\.attempt)).count == profile.mutationReceipts.count,
              profile.mutationReceipts.allSatisfy({ receipt in
                  validConfigurationKey(receipt.configurationKey) &&
                    (receipt.provider == .ethereum || receipt.provider == .solana) &&
                    ExtensionBridge.isValidEnqueueAttempt(receipt.attempt) &&
                    receipt.createdAt.timeIntervalSince1970.isFinite &&
                    receipt.expected.context == authoritySnapshot(profile, configurationKey: receipt.configurationKey).version.context &&
                    profile.origins[receipt.configurationKey] != nil
              }),
              (try? Self.encode(profile.mutationReceipts).count).map({ $0 <= Self.maximumMutationReceiptBytes }) == true,
              profile.origins.allSatisfy({ key, origin in
                  validConfigurationKey(key) && validOrigin(origin, sequence: profile.authoritySequence)
              }),
              active.count <= ExtensionBridge.maximumRequests,
              Dictionary(grouping: active, by: \.configurationKey).values.allSatisfy({
                  $0.count <= ExtensionBridge.maximumRequestsPerHost
              }),
              Set(profile.records.map(\.requestToken)).count == profile.records.count,
              Set(profile.records.map(\.nativeDeliveryNonce)).count ==
                profile.records.count,
              Set(profile.records.flatMap {
                  [$0.requestToken, $0.nativeDeliveryNonce.value]
              }).count == profile.records.count * 2,
              Set(profile.records.map(\.enqueueAttempt)).count == profile.records.count else {
            return nil
        }
        var parsedRequests = [ExtensionBridge.Handle: SafariRequest]()
        for record in profile.records {
            guard record.profileIdentifier == expectedIdentifier,
                  !record.host.isEmpty,
                  record.authority.context == authoritySnapshot(profile, configurationKey: record.configurationKey).version.context,
                  record.authorizedAccount.map(\.isValid) ?? true,
                  record.revisions.ethereum <= profile.authoritySequence,
                  record.revisions.solana <= profile.authoritySequence,
                  record.executionDeadline.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                  profile.origins[record.configurationKey] != nil,
                  ExtensionBridge.isValidIdentity(
                      host: record.host,
                      configurationKey: record.configurationKey
                  ),
                  ExtensionBridge.isValidEnqueueAttempt(record.enqueueAttempt),
                  record.createdAt <= record.admissionCreatedAt,
                  record.nativeApproval.map({
                      $0.approvedAt.timeIntervalSince1970.isFinite &&
                        $0.approvedAt >= record.createdAt
                  }) ?? true,
                  record.nativeExecutionContext.map({ context in
                      context.observedAt.timeIntervalSince1970.isFinite &&
                        context.executionDeadline.timeIntervalSince1970.isFinite &&
                        record.nativeApproval.map {
                            context.observedAt >= $0.approvedAt
                      } == true &&
                        context.executionDeadline >= context.observedAt
                  }) ?? true,
                  record.nativeDeliveryReceipt.map({
                      $0.nativeDeliveryNonce == record.nativeDeliveryNonce &&
                        $0.owner.isValid
                  }) ?? true else {
                return nil
            }
            if let requestData = record.state.requestData {
                guard requestData.count <= ExtensionBridge.maximumPayloadBytes,
                      let rawObject = try? JSONSerialization.jsonObject(
                          with: requestData
                      ) as? [String: Any],
                      ExtensionBridge.AuthorityVersion(rawValue: rawObject["authority"]) == record.authority,
                      ExtensionBridge.correlationFingerprint(rawObject) ==
                        record.requestFingerprint,
                      var request = parseRequest(rawObject),
                      request.id == record.id,
                      request.host == record.host,
                      request.configurationKey == record.configurationKey,
                      request.enqueueAttempt == record.enqueueAttempt,
                      ExtensionBridge.admissionDeadlineDisposition(
                          request.admissionDeadline,
                          now: record.admissionCreatedAt
                      ) == .admissible,
                      request.workflowVersion == ExtensionBridge.workflowVersion else {
                    return nil
                }
                request.authorizedAccount = record.authorizedAccount
                if case .unknown = request.body {
                    let authority = authoritySnapshot(profile, configurationKey: record.configurationKey)
                    if record.authority == authority.version {
                        request.connectedAccounts = [authority.ethereumAccount, authority.solanaAccount].compactMap { $0 }
                    }
                }
                parsedRequests[record.handle] = request
            }
            if let responseData = record.state.responseData,
               responseJSON(responseData, id: record.id) == nil {
                return nil
            }
            switch record.state {
            case .completed(let since, _, _):
                guard since >= record.createdAt else { return nil }
            case .pending, .claimed, .broadcastPrepared:
                break
            }
        }
        return ValidatedProfile(state: profile, parsedRequests: parsedRequests)
    }

    private func normalizeFutureDates(
        in profile: inout ProfileState,
        now: Date
    ) -> Bool {
        let futureLimit = now.addingTimeInterval(Self.futureSkew)
        var changed = false
        for index in profile.records.indices {
            var record = profile.records[index]
            if record.createdAt > futureLimit {
                record.createdAt = now
                changed = true
            }
            switch record.state {
            case .pending, .claimed, .broadcastPrepared:
                break
            case .completed(let since, let response, let acknowledged):
                if since > futureLimit {
                    record.state = .completed(
                        since: max(record.createdAt, now),
                        response: response,
                        acknowledged: acknowledged
                    )
                    changed = true
                }
            }
            profile.records[index] = record
        }
        return changed
    }

    private func snapshot(
        _ record: Record,
        request: SafariRequest?,
        sequence: Int
    ) -> ExtensionBridge.Snapshot? {
        let state: ExtensionBridge.Snapshot.State
        switch record.state {
        case .pending(_, let approval):
            guard let request else { return nil }
            let queuedApproval: ExtensionBridge.Snapshot.QueuedApproval
            switch approval {
            case .unowned:
                queuedApproval = .unowned
            case .delivered(let receipt):
                queuedApproval = .delivered(receipt)
            }
            state = .queued(request: request, approval: queuedApproval)
        case .claimed, .broadcastPrepared:
            guard let request else { return nil }
            state = .approving(
                request: request,
                nativeApproval: record.nativeApproval.map {
                    .init(receipt: $0.receipt, approvedAt: $0.approvedAt,
                          executionContext: record.nativeExecutionContext)
                }
            )
        case .completed:
            state = .responded
        }
        return ExtensionBridge.Snapshot(
            handle: record.handle,
            state: state,
            nativeDeliveryNonce: record.nativeDeliveryNonce,
            host: record.host,
            configurationKey: record.configurationKey,
            revisions: record.revisions,
            createdAt: record.createdAt,
            enqueueAttempt: record.enqueueAttempt,
            sequence: sequence
        )
    }

    private func makeRoomForAdmission(
        _ incoming: Record,
        in records: inout [Record],
        now: Date
    ) -> [ExtensionBridge.Handle]? {
        guard let incomingBytes = retainedStorageBytes(incoming) else { return nil }
        var totalBytes = incomingBytes
        var originBytes = incomingBytes
        var candidates = [(record: Record, bytes: Int, since: Date, index: Int)]()
        for (index, record) in records.enumerated() {
            guard let bytes = retainedStorageBytes(record) else { return nil }
            totalBytes += bytes
            if record.configurationKey == incoming.configurationKey {
                originBytes += bytes
            }
            if case .completed(let since, let response, let acknowledged) = record.state,
               canRetireAdmissionRecord(record, now: now),
               acknowledged || responseJSON(response, id: record.id)?["name"] as? String != "switchAccount" {
                candidates.append((record, bytes, since, index))
            }
        }
        candidates.sort {
            $0.since == $1.since ? $0.index < $1.index : $0.since < $1.since
        }
        var retired = Set<ExtensionBridge.Handle>()
        for candidate in candidates where
            originBytes > ExtensionBridge.maximumRetainedBytesPerOrigin &&
                candidate.record.configurationKey == incoming.configurationKey {
            retired.insert(candidate.record.handle)
            originBytes -= candidate.bytes
            totalBytes -= candidate.bytes
        }
        guard originBytes <= ExtensionBridge.maximumRetainedBytesPerOrigin else {
            return nil
        }
        for candidate in candidates where
            totalBytes > ExtensionBridge.maximumRetainedBytes &&
                !retired.contains(candidate.record.handle) {
            retired.insert(candidate.record.handle)
            totalBytes -= candidate.bytes
        }
        guard totalBytes <= ExtensionBridge.maximumRetainedBytes else { return nil }
        records.removeAll { retired.contains($0.handle) }
        return Array(retired)
    }

    private func retainedStorageBytes(_ record: Record) -> Int? {
        var metadata = record
        if record.state.isActive {
            metadata.state = .pending(request: Data(), approval: .unowned)
        }
        guard let data = try? Self.encode(metadata) else {
            return nil
        }
        return data.count + (record.state.isActive
            ? ExtensionBridge.maximumStoredRecordBytes + 32 * 1024
            : 0)
    }

    private func canRetireAdmissionRecord(_ record: Record, now: Date) -> Bool {
        let retryWindow = ExtensionBridge.requestTTL + Self.futureSkew
        return record.admissionCreatedAt.addingTimeInterval(retryWindow) <= now
    }

    private func boundedResponseData(
        _ response: ResponseToExtension,
        request: SafariRequest,
        recoveryResponseData: Data? = nil
    ) -> Data? {
        if let data = exactResponseData(response) { return data }
        if let recoveryResponseData { return recoveryResponseData }
        var fallback = ResponseToExtension(
            for: request,
            payload: .error(.internalError)
        )
        if response.approvalCommitted {
            fallback = fallback.markingApprovalCommitted()
        }
        return exactResponseData(fallback)
    }

    private func exactResponseData(_ response: ResponseToExtension) -> Data? {
        guard let data = ExtensionBridge.payloadData(response.json, options: [.sortedKeys]),
              data.count <= ExtensionBridge.maximumPayloadBytes,
              responseJSON(data, id: response.id) != nil else { return nil }
        return data
    }

    private func responseJSON(_ data: Data, id: Int) -> [String: Any]? {
        guard data.count <= ExtensionBridge.maximumPayloadBytes,
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let decoded = ResponseToExtension(json: response),
              decoded.id == id else { return nil }
        return decoded.json
    }

    private func acquireOperationLeaseLocked(
        handle: ExtensionBridge.Handle
    ) -> ExtensionBridge.OperationLease? {
        guard prepareDirectoriesLocked() else { return nil }
        let url = operationLockURL(handle)
        switch regularFileStatusLocked(at: url) {
        case .missing, .regular:
            break
        case .unsafe, .unavailable:
            return nil
        }
        let lock = CrossProcessFileLock(fileURL: url)
        do {
            try lock.acquire(
                timeoutNanoseconds: lockTimeout,
                pollNanoseconds: lockPoll
            )
            return .init(fileURL: url, lock: lock)
        } catch {
            return nil
        }
    }

    private func operationLockStatusLocked(
        handle: ExtensionBridge.Handle
    ) -> OperationLockStatus {
        operationLockStatusLocked(at: operationLockURL(handle))
    }

    private func executionDeadlineIsCurrent(_ deadline: Date?, now: Date) -> Bool {
        guard let deadline else { return false }
        let remaining = deadline.timeIntervalSince(now)
        return remaining > 0 && remaining <= Self.executionLifetime
    }

    private func executionAuthorityAuthorizesLocked(
        record: Record,
        authority: ExtensionBridge.ExecutionAuthority,
        now: Date
    ) -> Bool {
        switch authority {
        case .ordinary:
            if case .broadcastPrepared = record.state { return true }
            return record.nativeExecutionContext == nil && executionDeadlineIsCurrent(record.executionDeadline, now: now)
        case .mobileSigning(let deadline):
            return record.nativeExecutionContext == nil && deadline == record.executionDeadline && executionDeadlineIsCurrent(deadline, now: now)
        case .native(let expected):
            return !Task.isCancelled && record.nativeExecutionContext == expected &&
                now >= expected.observedAt &&
                now < expected.executionDeadline
        }
    }

    private func operationLockStatusLocked(at url: URL) -> OperationLockStatus {
        switch regularFileStatusLocked(at: url) {
        case .missing:
            return .unlocked
        case .regular:
            break
        case .unsafe:
            return .unsafe
        case .unavailable:
            return .unavailable
        }
        let lock = CrossProcessFileLock(fileURL: url)
        do {
            guard try lock.tryAcquireExisting() else { return .held }
            lock.release()
            return .unlocked
        } catch {
            return .unavailable
        }
    }

    private func removeOperationLockLocked(handle: ExtensionBridge.Handle) {
        removeOperationLockLocked(at: operationLockURL(handle))
    }

    private func removeOperationLockLocked(at url: URL) {
        guard case .unlocked = operationLockStatusLocked(at: url),
              case .regular = regularFileStatusLocked(at: url) else { return }
        try? removeItem(url)
    }

    private func uniqueToken(
        in records: [Record],
        excluding excluded: UUID? = nil
    ) -> UUID? {
        for _ in 0..<16 {
            let candidate = token()
            if candidate != excluded,
               !records.contains(where: {
                   $0.requestToken == candidate ||
                    $0.nativeDeliveryNonce.value == candidate
               }) {
                return candidate
            }
        }
        return nil
    }

    private func receiptMatches(
        _ receipt: ExtensionBridge.NativeDeliveryReceipt?,
        expected: ReceiptIdentity?
    ) -> Bool {
        guard let expected else { return receipt == nil }
        return receipt?.matches(
            nativeDeliveryNonce: expected.nativeDeliveryNonce,
            runtimeInstanceIdentifier: expected.runtimeInstanceIdentifier
        ) == true
    }

    private func nextID(excluding value: UUID) -> UUID? {
        for _ in 0..<16 {
            let candidate = token()
            if candidate != value { return candidate }
        }
        return nil
    }

    private func readProfileDataLocked(at url: URL) -> ProfileDataRead {
        switch regularFileStatusLocked(at: url) {
        case .missing:
            return .missing
        case .regular:
            break
        case .unsafe:
            return .corrupt
        case .unavailable:
            return .unavailable
        }
        do {
            guard let size = try readFileSize(url) else {
                return .unavailable
            }
            guard size > 0, size <= Self.maximumProfileBytes else {
                return .corrupt
            }
            let data = try readData(url)
            guard !data.isEmpty, data.count <= Self.maximumProfileBytes else {
                return .corrupt
            }
            return .data(data)
        } catch {
            return .unavailable
        }
    }

    private func writeProfileLocked(
        _ profile: ValidatedProfile,
        failureRecovery: WriteFailureRecovery = .none
    ) -> Bool {
        guard prepareDirectoriesLocked() else { return false }
        let url = profileURL(profile.state.profileIdentifier)
        switch regularFileStatusLocked(at: url) {
        case .missing, .regular:
            break
        case .unsafe, .unavailable:
            return false
        }
        guard let authorityData = try? Self.encode(profile.state.origins),
              authorityData.count <= Self.maximumAuthorityBytes,
              let data = try? Self.encode(profile.state),
              data.count <= Self.maximumProfileBytes else { return false }
        do {
            try atomicWrite(data, url)
            return true
        } catch {
            guard failureRecovery == .readBack,
                  case .data(let persistedData) = readProfileDataLocked(at: url) else {
                return false
            }
            return persistedData == data &&
                synchronizeProfileLocked(profile.state.profileIdentifier)
        }
    }

    private func synchronizeProfileLocked(_ profileIdentifier: UUID?) -> Bool {
        let url = profileURL(profileIdentifier)
        guard case .regular = regularFileStatusLocked(at: url) else { return false }
        do {
            try synchronizePublishedFile(url)
            return true
        } catch {
            return false
        }
    }

    private func synchronizedMutationResultLocked(
        _ profileIdentifier: UUID?
    ) -> ExtensionBridge.StoreMutationResult {
        synchronizeProfileLocked(profileIdentifier)
            ? .persisted
            : .retryablePersistenceFailure
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    private func regularFileStatusLocked(at url: URL) -> RegularFileStatus {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let type = attributes[.type] as? FileAttributeType else {
                return .unavailable
            }
            return type == .typeRegular ? .regular : .unsafe
        } catch {
            if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
                return .unsafe
            }
            return fileManager.fileExists(atPath: url.path) ? .unavailable : .missing
        }
    }

    private func directoryStatus(at url: URL) -> DirectoryStatus {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let type = attributes[.type] as? FileAttributeType else {
                return .unavailable
            }
            return type == .typeDirectory ? .directory : .unsafe
        } catch let error as CocoaError where error.code == .fileNoSuchFile ||
            error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .unavailable
        }
    }

    private func emptyProfile(_ profileIdentifier: UUID?) -> ValidatedProfile {
        ValidatedProfile(
            state: ProfileState(
                profileIdentifier: profileIdentifier,
                authorityEpoch: token()
            ),
            parsedRequests: [:]
        )
    }

    private func prepareDirectoriesLocked() -> Bool {
        guard let rootURL else { return false }
        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: rootURL.appendingPathComponent(
                    Self.profileDirectoryName,
                    isDirectory: true
                ),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: rootURL.appendingPathComponent(
                    Self.operationLockDirectoryName,
                    isDirectory: true
                ),
                withIntermediateDirectories: true
            )
            let profileAttributes = try fileManager.attributesOfItem(
                atPath: profileDirectoryURL.path
            )
            let lockAttributes = try fileManager.attributesOfItem(
                atPath: operationLockDirectoryURL.path
            )
            return profileAttributes[.type] as? FileAttributeType == .typeDirectory &&
                lockAttributes[.type] as? FileAttributeType == .typeDirectory
        } catch {
            return false
        }
    }

    private func withLock<T>(or fallback: T, _ body: () -> T) -> T {
        do { return try withRequiredLock(body) }
        catch { return fallback }
    }

    private func withRequiredLock<T>(_ body: () throws -> T) throws -> T {
        guard let rootURL, let storeLock else { throw WalletAuthorityRemovalError.unavailable }
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableRootURL = rootURL
            try mutableRootURL.setResourceValues(resourceValues)
            try storeLock.acquire(
                timeoutNanoseconds: lockTimeout,
                pollNanoseconds: lockPoll
            )
        } catch {
            throw WalletAuthorityRemovalError.unavailable
        }
        defer { storeLock.release() }
        return try body()
    }

    private func profileURL(_ profileIdentifier: UUID?) -> URL {
        let name = profileIdentifier?.uuidString.lowercased() ?? "default"
        return profileDirectoryURL
            .appendingPathComponent(name)
            .appendingPathExtension("state")
    }

    private func operationLockURL(_ handle: ExtensionBridge.Handle) -> URL {
        let profile = handle.profileIdentifier?.uuidString.lowercased() ?? "default"
        return operationLockDirectoryURL
            .appendingPathComponent("\(profile)-\(handle.token.rawValue)")
            .appendingPathExtension("lock")
    }

    private var profileDirectoryURL: URL {
        rootURL!.appendingPathComponent(Self.profileDirectoryName, isDirectory: true)
    }

    private var operationLockDirectoryURL: URL {
        rootURL!.appendingPathComponent(
            Self.operationLockDirectoryName,
            isDirectory: true
        )
    }

    private func profileFileIdentity(for url: URL) -> ProfileFileIdentity? {
        let name = url.lastPathComponent
        if name == "default.state" {
            return .init(identifier: nil)
        }
        guard name.hasSuffix(".state") else { return nil }
        let namespace = String(name.dropLast(".state".count))
        guard let identifier = UUID(uuidString: namespace),
              namespace == identifier.uuidString.lowercased(),
              name == "\(namespace).state" else { return nil }
        return .init(identifier: identifier)
    }
}
