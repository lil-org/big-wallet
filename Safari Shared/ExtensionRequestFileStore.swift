// ∅ 2026 lil org

import Foundation

final class ExtensionRequestFileStore: WalletSourceMutating {
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

    private enum ProfileRead {
        case state(ValidatedProfile)
        case corrupt
        case unavailable
    }

    private let clock: () -> Date
    private let token: () -> UUID
    private let files: ExtensionRequestStoreFiles
    private let codec: ExtensionRequestProfileCodec

    private typealias ProfileState = ExtensionRequestProfile.State
    private typealias Record = ExtensionRequestProfile.Record
    private typealias ValidatedProfile = ExtensionRequestProfile
    private typealias ReceiptIdentity = ExtensionRequestProfile.ReceiptIdentity
    private typealias WriteFailureRecovery = ExtensionRequestStoreFiles.WriteFailureRecovery

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
        clock = dependencies.clock
        token = dependencies.token
        codec = ExtensionRequestProfileCodec(parseRequest: dependencies.parseRequest)
        files = ExtensionRequestStoreFiles(
            rootURL: rootURL,
            directoryBoundary: directoryBoundary,
            dependencies: dependencies
        )
    }

    private enum AuthorityObservation {
        case snapshot(ExtensionBridge.AuthoritySnapshot), missing, needsRepair, unavailable
    }

    private func observeAuthority(configurationKey: String, profileIdentifier: UUID?) -> AuthorityObservation {
        files.withExistingStoreLock(unavailable: .unavailable, missing: .missing) {
            let url = files.profileURL(profileIdentifier)
            switch files.regularFileStatusLocked(at: url) {
            case .missing: return .missing
            case .regular: break
            case .unsafe, .unavailable: return .unavailable
            }
            switch readProfileFileLocked(
                at: url, profileIdentifier: profileIdentifier, now: clock(),
                recover: false, normalizeDates: false
            ) {
            case .state(let profile):
                return .snapshot(ExtensionRequestProfile.authoritySnapshot(profile.state, configurationKey: configurationKey))
            case .corrupt: return .needsRepair
            case .unavailable: return .unavailable
            }
        }
    }

    func configurationSnapshot(
        configurationKey: String,
        profileIdentifier: UUID?
    ) -> ExtensionBridge.AuthorityReadResult {
        guard ExtensionRequestProfile.validConfigurationKey(configurationKey) else { return .unavailable }
        switch observeAuthority(configurationKey: configurationKey, profileIdentifier: profileIdentifier) {
        case .snapshot(let snapshot): return .snapshot(snapshot)
        case .unavailable: return .unavailable
        case .missing, .needsRepair: break
        }
        return files.withLock(or: .unavailable) {
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: profileIdentifier, now: clock(), recover: true
            ) else { return .unavailable }
            let url = files.profileURL(profileIdentifier)
            if case .missing = files.regularFileStatusLocked(at: url) {
                guard writeProfileLocked(profile, failureRecovery: .readBack) else { return .unavailable }
            }
            return .snapshot(ExtensionRequestProfile.authoritySnapshot(profile.state, configurationKey: configurationKey))
        }
    }

    func revoke(
        configurationKey: String,
        provider: InpageProvider,
        attempt: String,
        expected: ExtensionBridge.AuthorityVersion,
        profileIdentifier: UUID?
    ) -> ExtensionBridge.AuthorityMutationResult {
        files.withLock(or: .unavailable) {
            let now = clock()
            guard ExtensionRequestProfile.validConfigurationKey(configurationKey),
                  provider == .ethereum || provider == .solana,
                  ExtensionBridge.isValidEnqueueAttempt(attempt),
                  case .state(var profile) = readProfileLocked(
                    profileIdentifier: profileIdentifier, now: now, recover: true
                  ) else { return .unavailable }
            guard persistProfileIdentityIfMissing(profile) else { return .unavailable }
            let current = ExtensionRequestProfile.authoritySnapshot(profile.state, configurationKey: configurationKey)
            if let receipt = profile.state.mutationReceipts.first(where: { $0.attempt == attempt }) {
                guard receipt.configurationKey == configurationKey,
                      receipt.provider == provider, receipt.expected == expected,
                      files.synchronizeProfileLocked(profileIdentifier) else { return .unavailable }
                return .revoked(current)
            }
            guard ExtensionRequestProfile.authorityMatches(expected, current: current.version, provider: provider) else {
                return .stale(current)
            }
            guard profile.revokeProvider(
                configurationKey: configurationKey, provider: provider,
                attempt: attempt, expected: expected, now: now
            ), writeProfileLocked(profile, failureRecovery: .readBack) else { return .unavailable }
            return .revoked(ExtensionRequestProfile.authoritySnapshot(profile.state, configurationKey: configurationKey))
        }
    }

    func perform<Payload, Result>(
        preparing: () throws -> PreparedWalletSourceMutation<Payload>,
        beforeCommit: () throws -> Void,
        commit: (Payload) throws -> Result
    ) throws -> Result {
        try files.withRequiredLock {
            let prepared = try preparing()
            try beforeCommit()
            for removal in prepared.authorityRemovals {
                try revokeWalletAuthorityLocked(matching: removal)
            }
            return try commit(prepared.payload)
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
        let candidates = try files.discoverProfileCandidatesForRemovalLocked()
        var profiles = [ValidatedProfile]()
        for candidate in candidates {
            guard case .regular = files.regularFileStatusLocked(at: candidate.url),
                  case .state(let profile) = readProfileFileLocked(
                    at: candidate.url, profileIdentifier: candidate.identity.identifier,
                    now: now, recover: true, normalizeDates: false
                  ) else { throw WalletAuthorityRemovalError.unavailable }
            profiles.append(profile)
        }
        for var profile in profiles {
            guard let changed = profile.revokeWalletAuthority(matching: removal, now: now) else {
                throw WalletAuthorityRemovalError.unavailable
            }
            if changed, !writeProfileLocked(profile, failureRecovery: .readBack) {
                throw WalletAuthorityRemovalError.unavailable
            }
            guard files.synchronizeProfileLocked(profile.state.profileIdentifier) else {
                throw WalletAuthorityRemovalError.unavailable
            }
        }
    }

    func listRecoveryRequests(profileIdentifier: UUID?) -> ExtensionBridge.RecoveryRequestsResult {
        files.withLock(or: .unavailable) {
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: profileIdentifier, now: clock(), recover: true
            ) else { return .unavailable }
            let active = profile.state.records.filter(\.state.isActive)
            let completed = profile.state.records.filter { !$0.state.isActive && !$0.responseAcknowledged }
            let manual = completed.filter { ExtensionRequestProfile.isManualSwitch($0, in: profile) }
            let ordinary = completed.reversed().filter { !ExtensionRequestProfile.isManualSwitch($0, in: profile) }
            let recovery = active + (manual + ordinary).prefix(max(0, ExtensionBridge.maximumRetainedRequests - active.count))
            return .available(recovery.map { record in
                .init(handle: record.handle, configurationKey: record.configurationKey,
                      manual: ExtensionRequestProfile.isManualSwitch(record, in: profile), state: ExtensionRequestProfile.manualSwitchRequest(record).state)
            })
        }
    }

    func authorityIsCurrent(handle: ExtensionBridge.Handle) -> Bool {
        files.withLock(or: false) {
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier, now: clock(), recover: true
            ), let record = profile.state.records.first(where: { $0.handle == handle }),
               record.state.isActive else { return false }
            return ExtensionRequestProfile.authorityIsCurrent(record, in: profile.state)
        }
    }

    private func persistProfileIdentityIfMissing(_ profile: ValidatedProfile) -> Bool {
        switch files.regularFileStatusLocked(at: files.profileURL(profile.state.profileIdentifier)) {
        case .missing: return writeProfileLocked(profile, failureRecovery: .readBack)
        case .regular: return true
        case .unsafe, .unavailable: return false
        }
    }

    func enqueue(
        ingress: ExtensionBridge.Ingress,
        profileIdentifier: UUID?
    ) -> ExtensionBridge.EnqueueResult {
        files.withLock(or: .unavailable) {
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
                guard files.synchronizeProfileLocked(profileIdentifier) else { return .unavailable }
                return .accepted(
                    handle: existing.handle,
                    approvalRequired: approvalRequired,
                    authority: ExtensionRequestProfile.authoritySnapshot(profile.state, configurationKey: existing.configurationKey),
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
            let currentAuthority = ExtensionRequestProfile.authoritySnapshot(profile.state, configurationKey: ingress.request.configurationKey)
            guard ExtensionRequestProfile.authorityMatches(ingress.authority, current: currentAuthority.version,
                                   provider: ingress.request.provider, requestName: ingress.request.name),
                  ExtensionRequestProfile.requestIsAuthorized(ingress.request, by: currentAuthority) else {
                return .unauthorized(currentAuthority)
            }
            guard ExtensionRequestProfile.pinOrigin(in: &profile.state, configurationKey: ingress.request.configurationKey, now: now) else {
                return .unavailable
            }
            let isManualSwitchRequest = ingress.request.name == "switchAccount" &&
                ingress.request.provider == .unknown
            if isManualSwitchRequest,
               let existing = profile.state.records.first(where: { record in
                   record.configurationKey == ingress.request.configurationKey &&
                       !record.responseAcknowledged && ExtensionRequestProfile.isManualSwitch(record, in: profile)
               }) {
                guard files.synchronizeProfileLocked(profileIdentifier) else { return .unavailable }
                return .accepted(
                    handle: existing.handle,
                    approvalRequired: existing.state.isActive,
                    authority: ExtensionRequestProfile.authoritySnapshot(profile.state, configurationKey: existing.configurationKey),
                    admissionKind: .coalesced,
                    nativeDeliveryNonce: existing.nativeDeliveryNonce
                )
            }

            let manualSwitches = isManualSwitchRequest ? profile.state.records.filter {
                !$0.responseAcknowledged && ExtensionRequestProfile.isManualSwitch($0, in: profile)
            }.map(ExtensionRequestProfile.manualSwitchRequest) : []
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

            guard let boundRequest = codec.bind(ingress.request, data: ingress.canonicalData, authority: currentAuthority),
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
                admissionCreatedAt: now,
                createdAt: now,
                state: .pending(request: boundData, approval: .unowned),
                nativeDeliveryNonce: .init(value: nativeDeliveryNonceValue)
            )
            if case .ethereum(let body) = boundRequest.request.body,
               body.method == .switchEthereumChain,
               let chainId = body.switchToChainId,
               String.hex(chainId, withPrefix: true) == currentAuthority.ethereumChainId {
                guard let response = ExtensionRequestProfileCodec.boundedResponseData(
                    ResponseToExtension(for: boundRequest.request, payload: .result(.null)),
                    request: boundRequest.request
                ) else { return .unavailable }
                record.complete(response: response, at: now)
            }
            if isManualSwitchRequest,
               !ExtensionRequestProfile.manualSwitchRequestsFit(manualSwitches + [ExtensionRequestProfile.manualSwitchRequest(record)]) {
                return .manualSwitchCapacityReached
            }
            guard let retiredHandles = profile.admit(
                record, request: boundRequest.request, now: now
            ) else { return .rejected }
            guard writeProfileLocked(profile, failureRecovery: .readBack) else {
                return .unavailable
            }
            for handle in retiredHandles {
                files.removeOperationLockLocked(handle: handle)

            }
            return .accepted(
                handle: record.handle,
                approvalRequired: record.state.isActive,
                authority: ExtensionRequestProfile.authoritySnapshot(profile.state, configurationKey: record.configurationKey),
                admissionKind: .new,
                nativeDeliveryNonce: record.nativeDeliveryNonce
            )
        }
    }

    func list(profileIdentifier: UUID?) -> ExtensionBridge.SnapshotsResult {
        return files.withLock(or: .unavailable) {
            let now = clock()
            guard files.prepareDirectoriesLocked() else { return .unavailable }
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
                guard let snapshot = ExtensionRequestProfile.snapshot(
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
        files.withLock(or: .unavailable) {
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
            guard let snapshot = ExtensionRequestProfile.snapshot(
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
            !$0.responseAcknowledged && ExtensionRequestProfile.isManualSwitch($0, in: profile)
        }.sorted {
            $0.admissionCreatedAt == $1.admissionCreatedAt
                ? $0.handle.requestToken < $1.handle.requestToken
                : $0.admissionCreatedAt < $1.admissionCreatedAt
        }.map(ExtensionRequestProfile.manualSwitchRequest)
        guard ExtensionRequestProfile.manualSwitchRequestsFit(requests) else { return .unavailable }
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
        }), !manualOnly || (!record.responseAcknowledged && ExtensionRequestProfile.isManualSwitch(record, in: profile)) else {
            return .missing
        }
        if case .completed = record.state { return .ready }
        return .pending
    }

    func loadManualSwitch(
        handle: ExtensionBridge.Handle,
        configurationKey: String
    ) -> ExtensionBridge.SnapshotResult {
        files.withLock(or: .unavailable) {
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .unavailable }
            guard let index = profile.state.records.firstIndex(where: {
                $0.handle == handle && $0.configurationKey == configurationKey &&
                    !$0.responseAcknowledged && ExtensionRequestProfile.isManualSwitch($0, in: profile)
            }) else { return .missing }
            guard let snapshot = ExtensionRequestProfile.snapshot(
                profile.state.records[index],
                request: profile.request(for: profile.state.records[index]),
                sequence: index
            ) else { return .unavailable }
            return .found(snapshot)
        }
    }

    func claim(
        handle: ExtensionBridge.Handle
    ) -> ExtensionBridge.ApprovalClaimResult {
        files.withLock(or: .unavailable) {
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .unavailable }
            guard let index = profile.state.records.firstIndex(where: { $0.handle == handle }) else {
                return .missing
            }
            switch profile.state.records[index].state {
            case .pending(_, let approval):
                guard case .unowned = approval else {
                    return .executing
                }
                guard let lease = files.acquireOperationLeaseLocked(handle: handle),
                      let claimID = nextID(excluding: handle.token.value) else {
                    return .unavailable
                }
                guard ExtensionRequestProfile.authorityIsCurrent(profile.state.records[index], in: profile.state),
                      let parsed = profile.request(for: profile.state.records[index]) else {
                    lease.release()
                    return .missing
                }
                let deadline = min(clock().addingTimeInterval(ExtensionRequestProfile.executionLifetime), parsed.admissionDeadline)
                guard profile.state.records[index].claim(id: claimID, approval: .ordinary(deadline: deadline)),
                      writeProfileLocked(profile) else {
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
        return files.withLock(or: .retryablePersistenceFailure) {
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: { $0.handle == handle }) else {
                return .ownershipLost
            }
            switch profile.state.records[index].recordDeliveryReceipt(receipt) {
            case .ownershipLost: return .ownershipLost
            case .unchanged: return synchronizedMutationResultLocked(handle.profileIdentifier)
            case .changed: break
            }
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
        return files.withLock(or: .retryablePersistenceFailure) {
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: { $0.handle == handle }) else {
                return .ownershipLost
            }
            switch profile.state.records[index].clearDeliveryReceipt(
                nonce: nativeDeliveryNonce, runtimeInstanceIdentifier: runtimeInstanceIdentifier
            ) {
            case .ownershipLost: return .ownershipLost
            case .unchanged: return synchronizedMutationResultLocked(handle.profileIdentifier)
            case .changed: break
            }
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
        files.withLock(or: .retryablePersistenceFailure) {
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: false
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: { $0.handle == handle }) else {
                return .ownershipLost
            }
            if case .completed(_, let response, _) = profile.state.records[index].state {
                guard files.synchronizeProfileLocked(handle.profileIdentifier) else {
                    return .retryablePersistenceFailure
                }
                if let json = ExtensionRequestProfileCodec.responseJSON(response, id: handle.id),
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
            guard profile.interruptNativeRecord(at: index, now: clock()),
                  writeProfileLocked(profile, failureRecovery: .readBack) else {
                return .retryablePersistenceFailure
            }
            files.removeOperationLockLocked(handle: handle)

            return hasBroadcastCheckpoint ? .responseReady : .interrupted
        }
    }

    func claimNativeExecution(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        approvedAt: Date
    ) -> ExtensionBridge.NativeExecutionClaimResult {
        files.withLock(or: .unavailable) {
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .unavailable }
            guard let index = profile.state.records.firstIndex(where: {
                $0.handle == handle
            }) else { return .missing }
            switch profile.state.records[index].state {
            case .pending(_, let pendingApproval):
                guard case .delivered(let receipt) = pendingApproval,
                      receipt.matches(
                          nativeDeliveryNonce: nativeDeliveryNonce,
                          runtimeInstanceIdentifier: runtimeInstanceIdentifier
                      ) else { return .ownershipLost }
                let now = clock()
                guard approvedAt.timeIntervalSince1970.isFinite,
                      approvedAt >= profile.state.records[index].createdAt,
                      approvedAt <= now,
                      ExtensionRequestProfile.authorityIsCurrent(profile.state.records[index], in: profile.state) else {
                    return .ownershipLost
                }
                let parsedRequest: SafariRequest
                switch profile.transitionExpiredPending(at: index, now: now) {
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
                        now.addingTimeInterval(ExtensionRequestProfile.executionLifetime),
                        parsedRequest.admissionDeadline
                    ),
                    fenceToken: token()
                )
                guard let claimID = nextID(excluding: handle.token.value),
                      let lease = files.acquireOperationLeaseLocked(handle: handle) else {
                    return .unavailable
                }
                guard profile.state.records[index].claim(id: claimID, approval: .native(approval, context: executionContext)),
                      writeProfileLocked(profile) else {
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
        files.withLock(or: .retryablePersistenceFailure) {
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
        files.withLock(or: .retryablePersistenceFailure) {
            let now = clock()
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: now,
                recover: true
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: { $0.handle == handle }),
                  let request = profile.request(for: profile.state.records[index]),
                  case .pending = profile.state.records[index].state,
                  ExtensionRequestProfile.receiptMatches(
                    profile.state.records[index].nativeDeliveryReceipt,
                    expected: expectedReceipt
                  ) else {
                return .ownershipLost
            }
            let response = ResponseToExtension(
                for: request,
                payload: .error(.userRejected)
            )
            guard let data = ExtensionRequestProfileCodec.boundedResponseData(response, request: request) else {
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
        files.withLock(or: .retryablePersistenceFailure) {
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: claim.handle.profileIdentifier,
                now: clock(),
                recover: false
            ) else { return .retryablePersistenceFailure }
            guard let record = profile.state.records.first(where: {
                $0.handle == claim.handle
            }), case .claimed(let claimID, _, _) = record.state,
                  claim.matches(handle: claim.handle, value: claimID),
                  ExtensionRequestProfile.authorityIsCurrent(record, in: profile.state),
                  ExtensionRequestProfile.executionDeadlineIsCurrent(record.claimedApproval?.deadline, now: clock()),
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
        files.withLock(or: .retryablePersistenceFailure) {
            let readTime = clock()
            guard recoveryResponse.id == permit.handle.id,
                  let responseData = ExtensionRequestProfileCodec.exactResponseData(recoveryResponse) else {
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
            case .claimed(let claimID, _, _):
                let authorizationTime = clock()
                guard permit.matches(handle: permit.handle, value: claimID),
                      permit.lease != nil,
                      ExtensionRequestProfile.authorityIsCurrent(profile.state.records[index], in: profile.state),
                      profile.state.records[index].authorizesExecution(
                          authority: authority,
                          now: authorizationTime,
                          isCancelled: Task.isCancelled
                      ) else { return .ownershipLost }
                guard profile.state.records[index].prepareBroadcast(recoveryResponse: responseData) else {
                    return .ownershipLost
                }
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
        files.withLock(or: .retryablePersistenceFailure) {
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
                guard files.synchronizeProfileLocked(permit.handle.profileIdentifier) else {
                    return .retryablePersistenceFailure
                }
                permit.releaseLease()
                return .persisted
            case .pending:
                return .ownershipLost
            }
            let authorizationTime = clock()
            guard permit.matches(handle: permit.handle, value: claimID),
                  (recoveryResponseData != nil || ExtensionRequestProfile.authorityIsCurrent(profile.state.records[index], in: profile.state)),
                  profile.state.records[index].authorizesExecution(
                      authority: authority,
                      now: authorizationTime,
                      isCancelled: Task.isCancelled
                  ),
                  let request = profile.request(for: profile.state.records[index]),
                  let responseData = ExtensionRequestProfileCodec.boundedResponseData(
                      response,
                      request: request,
                      recoveryResponseData: recoveryResponseData
                  ) else {
                return .ownershipLost
            }
            let completing = profile.state.records[index]
            if recoveryResponseData == nil {
                guard profile.applyAuthorityEffect(response, record: completing, now: authorizationTime) else { return .ownershipLost }
            }
            profile.complete(at: index, response: responseData, date: authorizationTime)
            guard writeProfileLocked(profile) else {
                return .retryablePersistenceFailure
            }
            permit.releaseLease()
            files.removeOperationLockLocked(handle: permit.handle)

            return .persisted
        }
    }

    func rollback(
        permit: ExtensionBridge.ExecutionPermit
    ) -> ExtensionBridge.StoreMutationResult {
        files.withLock(or: .retryablePersistenceFailure) {
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
            guard profile.interruptNativeRecord(at: index, now: now),
                  writeProfileLocked(profile, failureRecovery: .readBack) else {
                return .retryablePersistenceFailure
            }
            result = .persisted
        } else {
            profile.state.records[index].restorePendingClaim()
            switch profile.transitionExpiredPending(
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
        files.removeOperationLockLocked(handle: handle)

        return result
    }

    func prepareResponseDelivery(
        handle: ExtensionBridge.Handle,
        configurationKey: String
    ) -> ExtensionBridge.ResponseReadResult {
        files.withLock(or: .unavailable) {
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
                guard let response = ExtensionRequestProfileCodec.responseJSON(responseData, id: handle.id),
                      files.synchronizeProfileLocked(handle.profileIdentifier) else {
                    return .unavailable
                }
                return .response(["id": handle.id, "response": response,
                    "state": ExtensionRequestProfile.authoritySnapshot(profile.state, configurationKey: configurationKey).json])
            }
        }
    }

    func acknowledgeResponse(
        handle: ExtensionBridge.Handle,
        configurationKey: String
    ) -> ExtensionBridge.StoreMutationResult {
        files.withLock(or: .retryablePersistenceFailure) {
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: {
                $0.handle == handle && $0.configurationKey == configurationKey
            }) else { return .ownershipLost }
            switch profile.state.records[index].acknowledgeResponse() {
            case .notCompleted: return .retryablePersistenceFailure
            case .alreadyRecorded: return synchronizedMutationResultLocked(handle.profileIdentifier)
            case .recorded: break
            }
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
        files.withLock(or: .retryablePersistenceFailure) {
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
                  ExtensionRequestProfile.receiptMatches(
                    profile.state.records[index].nativeDeliveryReceipt,
                    expected: expectedReceipt
                  ) else {
                return .ownershipLost
            }
            let request: SafariRequest
            switch profile.transitionExpiredPending(
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
            guard let responseData = ExtensionRequestProfileCodec.boundedResponseData(response, request: request) else {
                return .retryablePersistenceFailure
            }
            guard ExtensionRequestProfile.authorityIsCurrent(profile.state.records[index], in: profile.state),
                  profile.applyAuthorityEffect(response, record: profile.state.records[index], now: now) else { return .ownershipLost }
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
        guard files.prepareDirectoriesLocked() else { return .unavailable }
        return readProfileFileLocked(
            at: files.profileURL(profileIdentifier),
            profileIdentifier: profileIdentifier,
            now: now,
            recover: recover
        )
    }

    private func readProfileObservational(profileIdentifier: UUID?) -> ProfileRead {
        files.withExistingStoreLock(
            unavailable: .unavailable,
            missing: .state(emptyProfile(profileIdentifier))
        ) {
            readProfileFileLocked(
                at: files.profileURL(profileIdentifier),
                profileIdentifier: profileIdentifier,
                now: clock(), recover: false, normalizeDates: false
            )
        }
    }

    private func readProfileFileLocked(
        at url: URL,
        profileIdentifier: UUID?,
        now: Date,
        recover: Bool,
        normalizeDates: Bool = true
    ) -> ProfileRead {
        let data: Data
        switch files.readProfileDataLocked(at: url) {
        case .missing: return .state(emptyProfile(profileIdentifier))
        case .data(let storedData): data = storedData
        case .corrupt: return .corrupt
        case .unavailable: return .unavailable
        }
        guard let decoded = codec.decodeProfile(
            data, expectedIdentifier: profileIdentifier,
            recoverAuthority: recover, now: now
        ) else { return .corrupt }
        var profile = decoded.profile
        if decoded.requiresAuthorityPublication {
            guard writeProfileLocked(profile, failureRecovery: .readBack) else { return .unavailable }
        }
        let normalizedDates = normalizeDates && profile.normalizeFutureDates(now: now)
        guard recover else { return .state(profile) }
        let abandonedHandles = Set(profile.state.records.compactMap { record -> ExtensionBridge.Handle? in
            switch record.state {
            case .claimed, .broadcastPrepared:
                return files.operationLockStatusLocked(handle: record.handle) == .unlocked ? record.handle : nil
            case .pending, .completed:
                return nil
            }
        })
        guard let maintenance = profile.maintain(now: now, abandonedHandles: abandonedHandles) else {
            return .unavailable
        }
        guard normalizedDates || maintenance.changed else { return .state(profile) }
        guard writeProfileLocked(profile) else { return .unavailable }
        for handle in maintenance.operationLocksToRemove {
            files.removeOperationLockLocked(handle: handle)
        }
        return .state(profile)
    }

    func performMaintenance() {
        let candidates = files.discoverProfileCandidates()
        for candidate in candidates {
            let maintained = files.withLock(or: false) {
                guard files.prepareDirectoriesLocked() else { return false }
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
        _ = files.withLock(or: false) {
            guard files.prepareDirectoriesLocked() else { return false }
            _ = readProfileFileLocked(
                at: files.profileURL(profileIdentifier),
                profileIdentifier: profileIdentifier,
                now: clock(),
                recover: true
            )
            return true
        }
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

    private func nextID(excluding value: UUID) -> UUID? {
        for _ in 0..<16 {
            let candidate = token()
            if candidate != value { return candidate }
        }
        return nil
    }

    private func writeProfileLocked(
        _ profile: ValidatedProfile,
        failureRecovery: WriteFailureRecovery = .none
    ) -> Bool {
        guard let data = ExtensionRequestProfileCodec.profileData(profile) else { return false }
        return files.publishProfileDataLocked(
            data, profileIdentifier: profile.state.profileIdentifier,
            failureRecovery: failureRecovery
        )
    }

    private func synchronizedMutationResultLocked(
        _ profileIdentifier: UUID?
    ) -> ExtensionBridge.StoreMutationResult {
        files.synchronizeProfileLocked(profileIdentifier)
            ? .persisted
            : .retryablePersistenceFailure
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

}
