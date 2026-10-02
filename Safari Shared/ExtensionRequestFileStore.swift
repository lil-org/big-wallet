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
    typealias CompleteChainAddition = (ExtensionBridge.ApprovedExecutionPermit) -> Bool

    struct Dependencies {
        let clock: () -> Date
        let token: () -> UUID
        let revocationEpoch: () -> UUID
        let crossProcessLock: CrossProcessFileLock?
        let crossProcessLockTimeoutNanoseconds: UInt64
        let crossProcessLockPollNanoseconds: UInt64
        let atomicWrite: AtomicWrite?
        let synchronizePublishedFile: SynchronizePublishedFile?
        let persistenceOperations: DurableProfilePersistence.Operations
        let readData: ReadData
        let readFileSize: ReadFileSize
        let removeItem: RemoveItem
        let completeChainAddition: CompleteChainAddition

        init(
            clock: @escaping () -> Date = Date.init,
            token: @escaping () -> UUID = UUID.init,
            revocationEpoch: @escaping () -> UUID = UUID.init,
            crossProcessLock: CrossProcessFileLock? = nil,
            crossProcessLockTimeoutNanoseconds: UInt64 = 1_000_000_000,
            crossProcessLockPollNanoseconds: UInt64 = 10_000_000,
            atomicWrite: AtomicWrite? = nil,
            synchronizePublishedFile: SynchronizePublishedFile? = nil,
            persistenceOperations: DurableProfilePersistence.Operations = .live,
            readData: @escaping ReadData = ExtensionRequestFileStore.defaultReadData,
            readFileSize: @escaping ReadFileSize = ExtensionRequestFileStore.defaultReadFileSize,
            removeItem: @escaping RemoveItem = ExtensionRequestFileStore.defaultRemoveItem,
            completeChainAddition: @escaping CompleteChainAddition =
                EthereumDappRequestProcessor.completeApprovedChainAddition
        ) {
            self.clock = clock
            self.token = token
            self.revocationEpoch = revocationEpoch
            self.crossProcessLock = crossProcessLock
            self.crossProcessLockTimeoutNanoseconds = crossProcessLockTimeoutNanoseconds
            self.crossProcessLockPollNanoseconds = crossProcessLockPollNanoseconds
            self.atomicWrite = atomicWrite
            self.synchronizePublishedFile = synchronizePublishedFile
            self.persistenceOperations = persistenceOperations
            self.readData = readData
            self.readFileSize = readFileSize
            self.removeItem = removeItem
            self.completeChainAddition = completeChainAddition
        }
    }

    private enum ProfileRead {
        case state(ValidatedProfile)
        case missing
        case corrupt
        case unavailable
    }

    private enum RevocationLedgerRead {
        case ledger(WalletAuthorityRevocationLedger)
        case resetRequired
        case unavailable
    }

    private let clock: () -> Date
    private let token: () -> UUID
    private let revocationEpoch: () -> UUID
    private let completeChainAddition: CompleteChainAddition
    private let files: ExtensionRequestStoreFiles
    private var codec: ExtensionRequestProfileCodec

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
        revocationEpoch = dependencies.revocationEpoch
        completeChainAddition = dependencies.completeChainAddition
        codec = ExtensionRequestProfileCodec()
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
            switch observeProfileFileLocked(
                at: url, profileIdentifier: profileIdentifier, now: clock()
            ) {
            case .state(let profile):
                switch readRevocationLedgerLocked() {
                case .ledger(let ledger):
                    if profile.state.revocationCursor.epoch == ledger.epoch,
                       profile.state.revocationCursor.sequence > ledger.sequence {
                        return .unavailable
                    }
                    guard profile.state.revocationCursor == ledger.cursor else { return .needsRepair }
                case .resetRequired: return .needsRepair
                case .unavailable: return .unavailable
                }
                return .snapshot(ExtensionRequestProfile.authoritySnapshot(profile.state, configurationKey: configurationKey))
            case .missing: return .missing
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
            guard case .state(let profile) = recoverProfileLocked(
                profileIdentifier: profileIdentifier, now: clock()
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
                  case .state(var profile) = recoverProfileLocked(
                    profileIdentifier: profileIdentifier, now: now
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
            try recordWalletAuthorityRemovalsLocked(prepared.authorityRemovals)
            return try commit(prepared.payload)
        }
    }

    private func recordWalletAuthorityRemovalsLocked(_ removals: [WalletAuthorityRemoval]) throws {
        guard removals.contains(where: {
            if case .accounts(let accounts) = $0 { return !accounts.isEmpty }
            return true
        }) else { return }
        var ledger: WalletAuthorityRevocationLedger
        switch readRevocationLedgerLocked() {
        case .ledger(let stored) where stored.sequence < Int.max:
            ledger = stored
        case .ledger, .resetRequired:
            ledger = WalletAuthorityRevocationLedger(epoch: revocationEpoch())
        case .unavailable:
            throw WalletAuthorityRemovalError.unavailable
        }
        do {
            guard try ledger.record(removals) else { return }
            guard files.publishRevocationLedgerDataLocked(try ledger.encoded()) else {
                throw WalletAuthorityRemovalError.unavailable
            }
        } catch {
            throw WalletAuthorityRemovalError.unavailable
        }
    }

    private func readRevocationLedgerLocked() -> RevocationLedgerRead {
        switch files.readRevocationLedgerDataLocked() {
        case .missing: return .resetRequired
        case .data(let data):
            guard let ledger = WalletAuthorityRevocationLedger.decode(data) else { return .resetRequired }
            return .ledger(ledger)
        case .unavailable: return .unavailable
        }
    }

    private func currentRevocationLedgerLocked() -> WalletAuthorityRevocationLedger? {
        switch readRevocationLedgerLocked() {
        case .ledger(let ledger): return ledger
        case .resetRequired:
            let ledger = WalletAuthorityRevocationLedger(epoch: revocationEpoch())
            guard let data = try? ledger.encoded(),
                  files.publishRevocationLedgerDataLocked(data) else { return nil }
            return ledger
        case .unavailable: return nil
        }
    }

    func listRecoveryRequests(profileIdentifier: UUID?) -> ExtensionBridge.RecoveryRequestsResult {
        files.withLock(or: .unavailable) {
            guard case .state(let profile) = recoverProfileLocked(
                profileIdentifier: profileIdentifier, now: clock()
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
            guard case .state(let profile) = recoverProfileLocked(
                profileIdentifier: handle.profileIdentifier, now: clock()
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
            guard case .state(var profile) = recoverProfileLocked(
                profileIdentifier: profileIdentifier,
                now: now
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

            guard let boundRequest = codec.bind(ingress.request, data: ingress.canonicalData, authority: currentAuthority) else { return .rejected }

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
                state: .pending(request: boundRequest.payload, approval: .unowned),
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
                record, now: now
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
            guard case .state(let profile) = recoverProfileLocked(
                profileIdentifier: profileIdentifier,
                now: now
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
            guard case .state(let profile) = recoverProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock()
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

    func responseStatus(
        handle: ExtensionBridge.Handle,
        configurationKey: String
    ) -> ExtensionBridge.ResponseStatusResult {
        let profile: ValidatedProfile
        switch observeProfile(
            profileIdentifier: handle.profileIdentifier
        ) {
        case .state(let loaded): profile = loaded
        case .missing: return .missing
        case .corrupt, .unavailable: return .unavailable
        }
        guard let record = profile.state.records.first(where: {
            $0.handle == handle && $0.configurationKey == configurationKey
        }) else {
            return .missing
        }
        if case .completed = record.state { return .ready }
        return .pending
    }

    func claim(
        handle: ExtensionBridge.Handle
    ) -> ExtensionBridge.ApprovalClaimResult {
        files.withLock(or: .unavailable) {
            guard case .state(var profile) = recoverProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock()
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
                let deadline = min(clock().addingTimeInterval(ExtensionBridge.executionLifetime), parsed.admissionDeadline)
                guard profile.state.records[index].claim(id: claimID, approval: .ordinary(deadline: deadline)),
                      writeProfileLocked(profile) else {
                    lease.release()
                    return .unavailable
                }
                return .claimed(.init(
                    record: profile.state.records[index],
                    request: parsed,
                    value: claimID,
                    lease: lease, authority: .ordinary(deadline: deadline)
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
            guard case .state(var profile) = recoverProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock()
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
            guard case .state(var profile) = recoverProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock()
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
            guard case .state(var profile) = reconcileProfileAuthorityLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock()
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
            guard case .state(var profile) = recoverProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock()
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
                    revisions: profile.state.records[index].revisions,
                    observedAt: now,
                    executionDeadline: min(
                        now.addingTimeInterval(ExtensionBridge.executionLifetime),
                        parsedRequest.admissionDeadline
                    )
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
                    record: profile.state.records[index],
                    request: parsedRequest,
                    value: claimID,
                    lease: lease,
                    authority: .native(approvedAt: approval.approvedAt, context: executionContext)
                )
                return .claimed(claim)
            case .claimed, .broadcastPrepared:
                return .executing
            case .completed:
                return .responded
            }
        }
    }

    func abandon(
        claim: ExtensionBridge.ApprovalClaim
    ) -> ExtensionBridge.StoreMutationResult {
        guard claim.lifecycle.closeUnapproved() else { return .ownershipLost }
        return recoverAbandoned(claim)
    }

    func completeImmediate(
        handle: ExtensionBridge.Handle,
        resolution: ImmediateResolution
    ) -> ExtensionBridge.StoreMutationResult {
        finish(handle: handle, expectedReceipt: nil, resolution: resolution)
    }

    func completeNativeImmediate(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        resolution: ImmediateResolution
    ) -> ExtensionBridge.StoreMutationResult {
        finish(
            handle: handle,
            expectedReceipt: .init(
                nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtimeInstanceIdentifier
            ),
            resolution: resolution
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
            guard case .state(var profile) = recoverProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: now
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

    func authorize(
        claim: ExtensionBridge.ApprovalClaim,
        approval: ResolvedDappApproval
    ) -> ExtensionBridge.AuthorizeExecutionResult {
        files.withLock(or: .retryablePersistenceFailure) {
            guard claim.lifecycle.isPreparing,
                  approval.binding == claim.binding,
                  approval.approvedAt.timeIntervalSince1970.isFinite,
                  approval.nativeReceipt == claim.nativeReceipt else { return .ownershipLost }
            guard case .state(let profile) = recoverProfileLocked(
                profileIdentifier: claim.handle.profileIdentifier, now: clock()
            ) else { return .retryablePersistenceFailure }
            let now = clock()
            guard let record = profile.state.records.first(where: { $0.handle == claim.handle }),
                  case .claimed(let claimID, _, _) = record.state,
                  claim.matches(handle: record.handle, value: claimID),
                  claim.binding.matches(record),
                  approval.approvedAt >= record.createdAt,
                  approval.approvedAt <= now,
                  record.nativeDeliveryReceipt == claim.nativeReceipt,
                  ExtensionRequestProfile.authorityIsCurrent(record, in: profile.state),
                  record.claimedApproval?.authority.isWithinClaimLifetime(at: now) == true,
                  record.authorizesExecution(authority: claim.authority, now: now, isCancelled: Task.isCancelled)
            else { return .ownershipLost }
            if case .native(let approvedAt, _) = claim.authority,
               approvedAt != approval.approvedAt { return .ownershipLost }
            guard claim.lifecycle.authorize(approval) else { return .ownershipLost }
            return .authorized(.init(claim: claim, approval: approval, clock: clock))
        }
    }

    func prepareBroadcast(
        permit: ExtensionBridge.ApprovedExecutionPermit,
        broadcast: PreparedBroadcast
    ) -> ExtensionBridge.BroadcastPreparationResult {
        files.withLock(or: .retryablePersistenceFailure) {
            let claim = permit.claim
            let readTime = clock()
            guard claim.lifecycle.hasActiveApprovedOwnership,
                  let recovery = broadcast.recoveryCompletion(for: permit),
                  let recoveryResponse = recovery.response(for: permit),
                  let responseData = ExtensionRequestProfileCodec.exactResponseData(recoveryResponse) else {
                return .ownershipLost
            }
            guard case .state(var profile) = recoverProfileLocked(
                profileIdentifier: permit.handle.profileIdentifier, now: readTime
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: { $0.handle == permit.handle }) else {
                return .ownershipLost
            }
            switch profile.state.records[index].state {
            case .claimed(let claimID, _, _):
                let authorizationTime = clock()
                guard permit.isExecuting,
                      claim.matches(handle: permit.handle, value: claimID),
                      claim.binding.matches(profile.state.records[index]),
                      ExtensionRequestProfile.authorityIsCurrent(profile.state.records[index], in: profile.state),
                      profile.state.records[index].authorizesExecution(
                          authority: permit.authority, now: authorizationTime, isCancelled: Task.isCancelled
                      ),
                      profile.state.records[index].prepareBroadcast(recoveryResponse: responseData) else {
                    return .ownershipLost
                }
                guard writeProfileLocked(profile) else { return .retryablePersistenceFailure }
            case .broadcastPrepared(let claimID, _, let existing, _):
                guard claim.matches(handle: permit.handle, value: claimID),
                      claim.binding.matches(profile.state.records[index]),
                      existing == responseData else { return .ownershipLost }
                guard files.synchronizeProfileLocked(permit.handle.profileIdentifier) else {
                    return .retryablePersistenceFailure
                }
            case .pending, .completed:
                return .ownershipLost
            }
            guard let dispatch = permit.checkpoint(broadcast: broadcast) else { return .ownershipLost }
            return .prepared(dispatch)
        }
    }

    func complete(
        claim: ExtensionBridge.ApprovalClaim,
        resolution: ImmediateResolution
    ) -> ExtensionBridge.StoreMutationResult {
        guard claim.lifecycle.canCompleteUnapproved,
              let response = resolution.response(for: claim.request) else { return .ownershipLost }
        defer { claim.releaseUnapproved() }
        return completeExecution(claim: claim, approvedPermit: nil) { _ in response }
    }

    func complete(
        permit: ExtensionBridge.ApprovedExecutionPermit,
        result: ApprovedCompletion
    ) -> ExtensionBridge.StoreMutationResult {
        guard let response = result.response(for: permit) else { return .ownershipLost }
        defer { permit.releaseLease() }
        return completeExecution(claim: permit.claim, approvedPermit: permit) { _ in
            guard response.addsEthereumChain else { return response }
            guard self.completeChainAddition(permit) else {
                return ApprovedCompletion.failure(
                    .init(message: Strings.somethingWentWrong), permit: permit
                )?.response(for: permit)
            }
            return response
        }
    }

    private func completeExecution(
        claim: ExtensionBridge.ApprovalClaim,
        approvedPermit: ExtensionBridge.ApprovedExecutionPermit?,
        response makeResponse: (SafariRequest) -> ResponseToExtension?
    ) -> ExtensionBridge.StoreMutationResult {
        files.withLock(or: .retryablePersistenceFailure) {
            guard approvedPermit != nil || claim.lifecycle.wasNeverAuthorized else { return .ownershipLost }
            let observingClosed = claim.lifecycle.isClosed
            let loaded = observingClosed ? observeProfileFileLocked(
                at: files.profileURL(claim.handle.profileIdentifier),
                profileIdentifier: claim.handle.profileIdentifier,
                now: clock()
            ) : recoverProfileLocked(
                profileIdentifier: claim.handle.profileIdentifier, now: clock()
            )
            guard case .state(var profile) = loaded else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: { $0.handle == claim.handle }),
                  claim.binding.matches(profile.state.records[index]) else { return .ownershipLost }
            let claimID: UUID
            let recoveryResponseData: Data?
            switch profile.state.records[index].state {
            case .claimed(let value, _, _):
                guard !observingClosed else { return .ownershipLost }
                claimID = value
                recoveryResponseData = nil
            case .broadcastPrepared(let value, _, let recoveryResponse, _):
                guard !observingClosed, approvedPermit != nil else { return .ownershipLost }
                claimID = value
                recoveryResponseData = recoveryResponse
            case .completed:
                guard files.synchronizeProfileLocked(claim.handle.profileIdentifier) else {
                    return .retryablePersistenceFailure
                }
                if let approvedPermit { approvedPermit.releaseLease() }
                else { claim.releaseUnapproved() }
                return .persisted
            case .pending:
                return .ownershipLost
            }
            let authorizationTime = clock()
            let ownsCompletion = approvedPermit == nil
                ? claim.lifecycle.isPreparing
                : claim.lifecycle.hasActiveApprovedOwnership
            guard ownsCompletion,
                  claim.matches(handle: claim.handle, value: claimID),
                  (recoveryResponseData != nil || approvedPermit?.isExecuting != false),
                  (recoveryResponseData != nil || ExtensionRequestProfile.authorityIsCurrent(profile.state.records[index], in: profile.state)),
                  (recoveryResponseData != nil || profile.state.records[index].authorizesExecution(
                      authority: claim.authority, now: authorizationTime, isCancelled: Task.isCancelled
                  )),
                  let request = profile.request(for: profile.state.records[index]),
                  let response = makeResponse(request),
                  let responseData = ExtensionRequestProfileCodec.boundedResponseData(
                      response, request: request, recoveryResponseData: recoveryResponseData
                  ) else { return .ownershipLost }
            let completing = profile.state.records[index]
            if recoveryResponseData == nil {
                guard profile.applyAuthorityEffect(response, record: completing, now: authorizationTime) else {
                    return .ownershipLost
                }
            }
            profile.complete(at: index, response: responseData, date: authorizationTime)
            let closed = approvedPermit == nil
                ? claim.lifecycle.closeUnapproved()
                : claim.lifecycle.closeApproved()
            guard closed else { return .ownershipLost }
            guard writeProfileLocked(profile) else { return .retryablePersistenceFailure }
            files.removeOperationLockLocked(handle: claim.handle)
            return .persisted
        }
    }

    func abandon(permit: ExtensionBridge.ApprovedExecutionPermit) -> ExtensionBridge.StoreMutationResult {
        guard permit.claim.lifecycle.closeApproved(includingCheckpoint: false) else { return .ownershipLost }
        return recoverAbandoned(permit.claim)
    }

    private func recoverAbandoned(
        _ claim: ExtensionBridge.ApprovalClaim
    ) -> ExtensionBridge.StoreMutationResult {
        files.withLock(or: .retryablePersistenceFailure) {
            guard case .state(let profile) = recoverProfileLocked(
                profileIdentifier: claim.handle.profileIdentifier, now: clock()
            ) else { return .retryablePersistenceFailure }
            guard let record = profile.state.records.first(where: { $0.handle == claim.handle }),
                  claim.binding.matches(record) else { return .ownershipLost }
            switch record.state {
            case .pending:
                guard record.nativeDeliveryReceipt == claim.nativeReceipt else { return .ownershipLost }
            case .completed:
                break
            case .claimed(let claimID, _, _), .broadcastPrepared(let claimID, _, _, _):
                return claim.matches(handle: record.handle, value: claimID)
                    ? .retryablePersistenceFailure
                    : .ownershipLost
            }
            return synchronizedMutationResultLocked(claim.handle.profileIdentifier)
        }
    }

    func prepareResponseDelivery(
        handle: ExtensionBridge.Handle,
        configurationKey: String
    ) -> ExtensionBridge.ResponseReadResult {
        files.withLock(or: .unavailable) {
            guard case .state(let profile) = recoverProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock()
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
            guard case .state(var profile) = recoverProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock()
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
        resolution: ImmediateResolution
    ) -> ExtensionBridge.StoreMutationResult {
        files.withLock(or: .retryablePersistenceFailure) {
            let now = clock()
            guard case .state(var profile) = reconcileProfileAuthorityLocked(
                    profileIdentifier: handle.profileIdentifier,
                    now: now
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
            guard let response = resolution.response(for: request) else { return .ownershipLost }
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

    private enum ProfileUpdateOperation {
        case reconcileAuthority
        case recoverRequests
    }

    private func observeProfile(profileIdentifier: UUID?) -> ProfileRead {
        files.withExistingStoreLock(unavailable: .unavailable, missing: .missing) {
            observeProfileFileLocked(
                at: files.profileURL(profileIdentifier),
                profileIdentifier: profileIdentifier,
                now: clock()
            )
        }
    }

    private func observeProfileFileLocked(
        at url: URL,
        profileIdentifier: UUID?,
        now: Date
    ) -> ProfileRead {
        let data: Data
        switch files.readProfileDataLocked(at: url) {
        case .missing: return .missing
        case .data(let storedData): data = storedData
        case .corrupt: return .corrupt
        case .unavailable: return .unavailable
        }
        guard let decoded = codec.decodeProfile(
            data, expectedIdentifier: profileIdentifier,
            recoverAuthority: false, now: now
        ) else { return .corrupt }
        return .state(decoded.profile)
    }

    private func reconcileProfileAuthorityLocked(
        profileIdentifier: UUID?,
        now: Date
    ) -> ProfileRead {
        guard files.prepareDirectoriesLocked() else { return .unavailable }
        return updateProfileFileLocked(
            at: files.profileURL(profileIdentifier),
            profileIdentifier: profileIdentifier,
            now: now,
            operation: .reconcileAuthority
        )
    }

    private func recoverProfileLocked(
        profileIdentifier: UUID?,
        now: Date
    ) -> ProfileRead {
        guard files.prepareDirectoriesLocked() else { return .unavailable }
        return recoverProfileFileLocked(
            at: files.profileURL(profileIdentifier),
            profileIdentifier: profileIdentifier,
            now: now
        )
    }

    private func recoverProfileFileLocked(
        at url: URL,
        profileIdentifier: UUID?,
        now: Date
    ) -> ProfileRead {
        updateProfileFileLocked(
            at: url, profileIdentifier: profileIdentifier,
            now: now, operation: .recoverRequests
        )
    }

    private func updateProfileFileLocked(
        at url: URL,
        profileIdentifier: UUID?,
        now: Date,
        operation: ProfileUpdateOperation
    ) -> ProfileRead {
        guard let ledger = currentRevocationLedgerLocked() else { return .unavailable }
        let data: Data
        switch files.readProfileDataLocked(at: url) {
        case .missing:
            return .state(emptyProfile(profileIdentifier, revocationCursor: ledger.cursor))
        case .data(let storedData): data = storedData
        case .corrupt: return .corrupt
        case .unavailable: return .unavailable
        }
        let decoded: ExtensionRequestProfileCodec.DecodedProfile?
        switch operation {
        case .reconcileAuthority:
            decoded = codec.decodeProfile(
                data, expectedIdentifier: profileIdentifier, recoverAuthority: false, now: now
            )
        case .recoverRequests:
            decoded = codec.decodeProfile(
                data, expectedIdentifier: profileIdentifier, recoverAuthority: true, now: now
            )
        }
        guard let decoded else { return .corrupt }
        var profile = decoded.profile
        guard let reconciled = profile.reconcileWalletAuthority(with: ledger, now: now) else {
            return .unavailable
        }
        let requiresReadBack = decoded.requiresAuthorityPublication || reconciled
        let normalizedDates = profile.normalizeFutureDates(now: now)
        var changed = requiresReadBack || normalizedDates
        var locksToRemove = [ExtensionBridge.Handle]()
        switch operation {
        case .reconcileAuthority:
            break
        case .recoverRequests:
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
            changed = changed || maintenance.changed
            locksToRemove = maintenance.operationLocksToRemove
        }
        guard changed else { return .state(profile) }
        guard writeProfileLocked(profile, failureRecovery: requiresReadBack ? .readBack : .none) else {
            return .unavailable
        }
        for handle in locksToRemove {
            files.removeOperationLockLocked(handle: handle)
        }
        return .state(profile)
    }

    func performMaintenance() {
        let candidates = files.withLock(or: []) { files.discoverProfileCandidates() }
        for candidate in candidates {
            let maintained = files.withLock(or: false) {
                guard files.prepareDirectoriesLocked() else { return false }
                _ = recoverProfileFileLocked(
                    at: candidate.url,
                    profileIdentifier: candidate.identity.identifier,
                    now: clock()
                )
                return true
            }
            if !maintained { return }
        }
    }

    func performMaintenance(profileIdentifier: UUID?) {
        _ = files.withLock(or: false) {
            guard files.prepareDirectoriesLocked() else { return false }
            _ = recoverProfileFileLocked(
                at: files.profileURL(profileIdentifier),
                profileIdentifier: profileIdentifier,
                now: clock()
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

    private func emptyProfile(
        _ profileIdentifier: UUID?,
        revocationCursor: WalletAuthorityRevocationLedger.Cursor
    ) -> ValidatedProfile {
        ValidatedProfile(
            state: ProfileState(
                profileIdentifier: profileIdentifier,
                authorityEpoch: token(),
                revocationCursor: revocationCursor
            )
        )
    }

}

extension ExtensionRequestProfile {
    fileprivate static func snapshot(
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
            sequence: sequence,
            requestBinding: request.map { .init(record: record, request: $0) }
        )
    }

}

extension ExtensionBridge {
    struct RequestBinding: Equatable, @unchecked Sendable {
        let handle: Handle
        let request: SafariRequest
        fileprivate let fingerprint: Data
        fileprivate let authority: AuthorityVersion

        fileprivate init(record: ExtensionRequestProfile.Record, request: SafariRequest) {
            handle = record.handle
            self.request = request
            fingerprint = record.requestFingerprint
            authority = record.authority
        }

        fileprivate func matches(_ record: ExtensionRequestProfile.Record) -> Bool {
            handle == record.handle && fingerprint == record.requestFingerprint && authority == record.authority
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.handle == rhs.handle && lhs.fingerprint == rhs.fingerprint && lhs.authority == rhs.authority
        }
    }

    fileprivate final class ExecutionLifecycle: @unchecked Sendable {
        private enum AuthorizationStage { case before, after }
        private enum DispatchSlot { case ready, consumed }
        private enum Phase {
            case claimed, preparing, authorized, executing
            case checkpointed(PreparedBroadcast, DispatchSlot)
            case closed(AuthorizationStage)
        }
        private enum SigningSlot {
            case unissued, issued, bound(UUID), signing(UUID), signed(UUID), finished
        }

        let binding: RequestBinding
        let authority: ExecutionAuthority
        let value: UUID
        let nativeReceipt: NativeDeliveryReceipt?
        let executionID = UUID()
        let signingDeadline: Date
        private let lease: OperationLease
        private let lock = NSLock()
        private var phase = Phase.claimed
        private var signing = SigningSlot.unissued

        init(
            record: ExtensionRequestProfile.Record,
            request: SafariRequest,
            value: UUID,
            lease: OperationLease,
            authority: ExecutionAuthority
        ) {
            binding = .init(record: record, request: request)
            self.authority = authority
            self.value = value
            self.lease = lease
            nativeReceipt = record.nativeDeliveryReceipt
            signingDeadline = authority.signingDeadline(for: request)
        }

        var isPreparing: Bool {
            lock.withLock {
                if case .preparing = phase { return true }
                return false
            }
        }

        var wasNeverAuthorized: Bool {
            lock.withLock {
                switch phase {
                case .claimed, .preparing, .closed(.before): true
                case .authorized, .executing, .checkpointed, .closed(.after): false
                }
            }
        }

        var canCompleteUnapproved: Bool {
            lock.withLock {
                switch phase {
                case .preparing, .closed(.before): true
                case .claimed, .authorized, .executing, .checkpointed, .closed(.after): false
                }
            }
        }

        var hasActiveApprovedOwnership: Bool {
            lock.withLock {
                switch phase {
                case .authorized, .executing, .checkpointed: true
                case .claimed, .preparing, .closed: false
                }
            }
        }

        var isClosed: Bool {
            lock.withLock {
                if case .closed = phase { return true }
                return false
            }
        }

        func adoptForExecution() -> Bool {
            lock.withLock {
                guard case .claimed = phase else { return false }
                phase = .preparing
                return true
            }
        }

        func authorize(_ approval: ResolvedDappApproval) -> Bool {
            lock.withLock {
                guard case .preparing = phase, approval.consumeAuthorization() else { return false }
                phase = .authorized
                return true
            }
        }

        func consumeExecution(now: Date) -> Bool {
            lock.withLock {
                guard case .authorized = phase, executionTimeIsCurrent(now) else { return false }
                phase = .executing
                return true
            }
        }

        func isExecuting(now: Date) -> Bool {
            lock.withLock {
                guard case .executing = phase else { return false }
                return executionTimeIsCurrent(now)
            }
        }

        private func executionTimeIsCurrent(_ now: Date) -> Bool {
            authority.isWithinExecutionWindow(at: now)
        }

        private func signingTimeIsCurrent(_ now: Date) -> Bool {
            now < signingDeadline && executionTimeIsCurrent(now)
        }

        func consumeSigningOperation(now: Date) -> Bool {
            lock.withLock {
                guard signingTimeIsCurrent(now), case .unissued = signing else { return false }
                switch phase {
                case .authorized, .executing:
                    signing = .issued
                    return true
                case .claimed, .preparing, .checkpointed, .closed:
                    return false
                }
            }
        }

        func bindSigningOperation(to sessionID: UUID, now: Date) -> Bool {
            lock.withLock {
                guard signingTimeIsCurrent(now), case .issued = signing else { return false }
                switch phase {
                case .authorized, .executing:
                    signing = .bound(sessionID)
                    return true
                case .claimed, .preparing, .checkpointed, .closed:
                    return false
                }
            }
        }

        func beginSigningAttempt(for sessionID: UUID, now: Date) -> Bool {
            lock.withLock {
                guard case .executing = phase, signingTimeIsCurrent(now),
                      case .bound(let boundID) = signing, boundID == sessionID else { return false }
                signing = .signing(sessionID)
                return true
            }
        }

        func consumeSigningUse(now: Date) -> Bool {
            lock.withLock {
                guard case .executing = phase, signingTimeIsCurrent(now),
                      case .signing(let sessionID) = signing else { return false }
                signing = .signed(sessionID)
                return true
            }
        }

        func finishSigningAttempt(for sessionID: UUID) {
            lock.withLock {
                switch signing {
                case .bound(let current), .signing(let current), .signed(let current):
                    if current == sessionID { signing = .finished }
                case .unissued, .issued, .finished:
                    break
                }
            }
        }

        func isSigningAttemptCurrent(for sessionID: UUID, now: Date) -> Bool {
            lock.withLock {
                guard case .executing = phase, signingTimeIsCurrent(now) else { return false }
                switch signing {
                case .signing(let current), .signed(let current): return current == sessionID
                case .unissued, .issued, .bound, .finished: return false
                }
            }
        }

        func isSigningAuthorized(now: Date) -> Bool {
            lock.withLock {
                guard case .executing = phase else { return false }
                return signingTimeIsCurrent(now)
            }
        }

        func checkpoint(broadcast: PreparedBroadcast) -> Bool {
            lock.withLock {
                switch phase {
                case .executing:
                    phase = .checkpointed(broadcast, .ready)
                    return true
                case .checkpointed(let checkpointed, _):
                    return checkpointed.hasSameIdentity(as: broadcast)
                case .claimed, .preparing, .authorized, .closed:
                    return false
                }
            }
        }

        func consumeDispatch(broadcast: PreparedBroadcast) -> Bool {
            lock.withLock {
                guard case .checkpointed(let checkpointed, .ready) = phase,
                      checkpointed.hasSameIdentity(as: broadcast) else { return false }
                phase = .checkpointed(checkpointed, .consumed)
                return true
            }
        }

        @discardableResult
        func closeUnapproved() -> Bool {
            let closed = lock.withLock {
                switch phase {
                case .claimed, .preparing:
                    phase = .closed(.before)
                    return true
                case .authorized, .executing, .checkpointed, .closed:
                    return false
                }
            }
            if closed { lease.release() }
            return closed
        }

        @discardableResult
        func closeApproved(includingCheckpoint: Bool = true) -> Bool {
            let closed = lock.withLock {
                switch phase {
                case .authorized, .executing:
                    phase = .closed(.after)
                    return true
                case .checkpointed where includingCheckpoint:
                    phase = .closed(.after)
                    return true
                case .claimed, .preparing, .checkpointed, .closed:
                    return false
                }
            }
            if closed { lease.release() }
            return closed
        }

        deinit { lease.release() }
    }

    struct ApprovalClaim: Equatable, Sendable {
        fileprivate let lifecycle: ExecutionLifecycle

        var binding: RequestBinding { lifecycle.binding }
        var handle: Handle { binding.handle }
        var request: SafariRequest { binding.request }
        var authority: ExecutionAuthority { lifecycle.authority }
        var executionDeadline: Date { authority.executionDeadline }
        fileprivate var nativeReceipt: NativeDeliveryReceipt? { lifecycle.nativeReceipt }

        fileprivate init(
            record: ExtensionRequestProfile.Record,
            request: SafariRequest,
            value: UUID,
            lease: OperationLease,
            authority: ExecutionAuthority
        ) {
            lifecycle = ExecutionLifecycle(
                record: record, request: request, value: value, lease: lease, authority: authority
            )
        }

        fileprivate func matches(handle: Handle, value: UUID) -> Bool {
            self.handle == handle && lifecycle.value == value
        }

        func matchesConsent(_ consent: ReviewConsent) -> Bool {
            guard binding == consent.binding, nativeReceipt == consent.nativeReceipt else { return false }
            if case .native(let approvedAt, _) = authority { return approvedAt == consent.approvedAt }
            return true
        }

        func adoptForExecution() -> Bool { lifecycle.adoptForExecution() }
        func releaseUnapproved() { lifecycle.closeUnapproved() }

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.lifecycle === rhs.lifecycle }
    }

    final class ApprovedExecutionPermit: Equatable, @unchecked Sendable {
        fileprivate let claim: ApprovalClaim
        private let resolvedApproval: ResolvedDappApproval
        private let clock: () -> Date

        var executionID: UUID { claim.lifecycle.executionID }
        var signingDeadline: Date { claim.lifecycle.signingDeadline }
        var handle: Handle { claim.handle }
        var request: SafariRequest { claim.request }
        var authority: ExecutionAuthority { claim.authority }
        var executionDeadline: Date { claim.executionDeadline }
        var approval: DappApprovalValidator.Approval { resolvedApproval.approval }

        fileprivate init(claim: ApprovalClaim, approval: ResolvedDappApproval, clock: @escaping () -> Date) {
            self.claim = claim
            resolvedApproval = approval
            self.clock = clock
        }

        func consumeExecution() -> Bool { claim.lifecycle.consumeExecution(now: clock()) }
        var isExecuting: Bool { claim.lifecycle.isExecuting(now: clock()) }
        func releaseLease() { claim.lifecycle.closeApproved() }
        func consumeSigningOperation() -> Bool { claim.lifecycle.consumeSigningOperation(now: clock()) }
        func bindSigningOperation(to sessionID: UUID) -> Bool {
            claim.lifecycle.bindSigningOperation(to: sessionID, now: clock())
        }
        func beginSigningAttempt(for sessionID: UUID) -> Bool {
            claim.lifecycle.beginSigningAttempt(for: sessionID, now: clock())
        }
        func consumeSigningUse() -> Bool { claim.lifecycle.consumeSigningUse(now: clock()) }
        func finishSigningAttempt(for sessionID: UUID) {
            claim.lifecycle.finishSigningAttempt(for: sessionID)
        }
        func isSigningAttemptCurrent(for sessionID: UUID) -> Bool {
            claim.lifecycle.isSigningAttemptCurrent(for: sessionID, now: clock())
        }
        var isSigningAuthorized: Bool { claim.lifecycle.isSigningAuthorized(now: clock()) }

        fileprivate func checkpoint(broadcast: PreparedBroadcast) -> BroadcastDispatchPermit? {
            guard claim.lifecycle.checkpoint(broadcast: broadcast) else { return nil }
            return BroadcastDispatchPermit(broadcast: broadcast, approvedPermit: self)
        }

        deinit { releaseLease() }

        static func == (lhs: ApprovedExecutionPermit, rhs: ApprovedExecutionPermit) -> Bool { lhs === rhs }
    }

    final class BroadcastDispatchPermit: Equatable, @unchecked Sendable {
        let broadcast: PreparedBroadcast
        let approvedPermit: ApprovedExecutionPermit

        fileprivate init(broadcast: PreparedBroadcast, approvedPermit: ApprovedExecutionPermit) {
            self.broadcast = broadcast
            self.approvedPermit = approvedPermit
        }

        func consume() -> Bool {
            approvedPermit.claim.lifecycle.consumeDispatch(broadcast: broadcast)
        }

        static func == (lhs: BroadcastDispatchPermit, rhs: BroadcastDispatchPermit) -> Bool {
            lhs.approvedPermit == rhs.approvedPermit && lhs.broadcast.hasSameIdentity(as: rhs.broadcast)
        }
    }
}
