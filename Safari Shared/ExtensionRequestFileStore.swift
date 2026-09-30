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
            removeItem: @escaping RemoveItem = ExtensionRequestFileStore.defaultRemoveItem
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
            switch readProfileFileLocked(
                at: url, profileIdentifier: profileIdentifier, now: clock(),
                recover: false, normalizeDates: false, reconcileRevocations: false
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

    func responseStatus(
        handle: ExtensionBridge.Handle,
        configurationKey: String
    ) -> ExtensionBridge.ResponseStatusResult {
        let profile: ValidatedProfile
        switch readProfileObservational(
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
                    revisions: profile.state.records[index].revisions,
                    observedAt: now,
                    executionDeadline: min(
                        now.addingTimeInterval(ExtensionRequestProfile.executionLifetime),
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
                    handle: handle,
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
                  claim.matches(handle: claim.handle, value: claimID),
                  claim.lease.isUnconsumed else {
                return .ownershipLost
            }
            return abandonClaimLocked(
                in: &profile,
                at: index,
                now: now,
                releaseLease: claim.lease.release
            )
        }
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
                recover: true
            ) else { return .retryablePersistenceFailure }
            guard let record = profile.state.records.first(where: {
                $0.handle == claim.handle
            }), case .claimed(let claimID, _, _) = record.state,
                  claim.matches(handle: claim.handle, value: claimID),
                  ExtensionRequestProfile.authorityIsCurrent(record, in: profile.state),
                  ExtensionRequestProfile.executionDeadlineIsCurrent(record.claimedApproval?.deadline, now: clock()),
                  record.claimedApproval?.authority == claim.authority,
                  let request = profile.request(for: record),
                  claim.lease.consume() else { return .ownershipLost }
            return .began(.init(claim: claim, record: record, request: request))
        }
    }

    func authorize(
        reservation: ExtensionBridge.ExecutionReservation,
        approval: ResolvedDappApproval
    ) -> ExtensionBridge.AuthorizeExecutionResult {
        files.withLock(or: .retryablePersistenceFailure) {
            let now = clock()
            guard reservation.lease.isActive,
                  approval.binding == reservation.binding,
                  approval.approvedAt.timeIntervalSince1970.isFinite,
                  approval.approvedAt <= now,
                  approval.nativeReceipt == reservation.nativeReceipt else { return .ownershipLost }
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: reservation.handle.profileIdentifier, now: now, recover: true
            ) else { return .retryablePersistenceFailure }
            guard let record = profile.state.records.first(where: { $0.handle == reservation.handle }),
                  case .claimed(let claimID, _, _) = record.state,
                  reservation.matches(handle: record.handle, value: claimID),
                  reservation.binding.matches(record),
                  approval.approvedAt >= record.createdAt,
                  ExtensionRequestProfile.authorityIsCurrent(record, in: profile.state),
                  record.authorizesExecution(authority: reservation.authority, now: now, isCancelled: Task.isCancelled)
            else { return .ownershipLost }
            if case .native(let approvedAt, _) = reservation.authority,
               approvedAt != approval.approvedAt { return .ownershipLost }
            guard !reservation.authorization.isAuthorized,
                  approval.consumeAuthorization(),
                  reservation.authorization.consume(lease: reservation.lease) else { return .ownershipLost }
            return .authorized(.init(reservation: reservation, approval: approval, clock: clock))
        }
    }

    func prepareBroadcast(
        permit: ExtensionBridge.ApprovedExecutionPermit,
        broadcast: PreparedBroadcast
    ) -> ExtensionBridge.BroadcastPreparationResult {
        files.withLock(or: .retryablePersistenceFailure) {
            let reservation = permit.reservation
            let readTime = clock()
            guard reservation.lease.isActive,
                  let recovery = broadcast.recoveryCompletion(for: permit),
                  let recoveryResponse = recovery.response(for: permit),
                  let responseData = ExtensionRequestProfileCodec.exactResponseData(recoveryResponse) else {
                return .ownershipLost
            }
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: permit.handle.profileIdentifier, now: readTime, recover: true
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: { $0.handle == permit.handle }) else {
                return .ownershipLost
            }
            switch profile.state.records[index].state {
            case .claimed(let claimID, _, _):
                let authorizationTime = clock()
                guard permit.isExecuting,
                      reservation.matches(handle: permit.handle, value: claimID),
                      reservation.binding.matches(profile.state.records[index]),
                      ExtensionRequestProfile.authorityIsCurrent(profile.state.records[index], in: profile.state),
                      profile.state.records[index].authorizesExecution(
                          authority: permit.authority, now: authorizationTime, isCancelled: Task.isCancelled
                      ),
                      profile.state.records[index].prepareBroadcast(recoveryResponse: responseData) else {
                    return .ownershipLost
                }
                guard writeProfileLocked(profile) else { return .retryablePersistenceFailure }
            case .broadcastPrepared(let claimID, _, let existing, _):
                guard reservation.matches(handle: permit.handle, value: claimID),
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
        reservation: ExtensionBridge.ExecutionReservation,
        resolution: ImmediateResolution
    ) -> ExtensionBridge.StoreMutationResult {
        guard !reservation.authorization.isAuthorized else { return .ownershipLost }
        return completeExecution(reservation: reservation, approvedPermit: nil) { request in
            resolution.response(for: request)
        }
    }

    func complete(
        permit: ExtensionBridge.ApprovedExecutionPermit,
        result: ApprovedCompletion
    ) -> ExtensionBridge.StoreMutationResult {
        guard let response = result.response(for: permit) else { return .ownershipLost }
        return completeExecution(reservation: permit.reservation, approvedPermit: permit) { _ in response }
    }

    private func completeExecution(
        reservation: ExtensionBridge.ExecutionReservation,
        approvedPermit: ExtensionBridge.ApprovedExecutionPermit?,
        response makeResponse: (SafariRequest) -> ResponseToExtension?
    ) -> ExtensionBridge.StoreMutationResult {
        files.withLock(or: .retryablePersistenceFailure) {
            let readTime = clock()
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: reservation.handle.profileIdentifier, now: readTime, recover: true
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: { $0.handle == reservation.handle }) else {
                return .ownershipLost
            }
            let claimID: UUID
            let recoveryResponseData: Data?
            switch profile.state.records[index].state {
            case .claimed(let value, _, _):
                claimID = value
                recoveryResponseData = nil
            case .broadcastPrepared(let value, _, let recoveryResponse, _):
                guard approvedPermit != nil else { return .ownershipLost }
                claimID = value
                recoveryResponseData = recoveryResponse
            case .completed:
                guard files.synchronizeProfileLocked(reservation.handle.profileIdentifier) else {
                    return .retryablePersistenceFailure
                }
                reservation.lease.release()
                return .persisted
            case .pending:
                return .ownershipLost
            }
            let authorizationTime = clock()
            guard reservation.lease.isActive,
                  reservation.matches(handle: reservation.handle, value: claimID),
                  reservation.binding.matches(profile.state.records[index]),
                  (approvedPermit != nil || !reservation.authorization.isAuthorized),
                  (recoveryResponseData != nil || approvedPermit?.isExecuting != false),
                  (recoveryResponseData != nil || ExtensionRequestProfile.authorityIsCurrent(profile.state.records[index], in: profile.state)),
                  (recoveryResponseData != nil || profile.state.records[index].authorizesExecution(
                      authority: reservation.authority, now: authorizationTime, isCancelled: Task.isCancelled
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
            guard writeProfileLocked(profile) else { return .retryablePersistenceFailure }
            reservation.lease.release()
            files.removeOperationLockLocked(handle: reservation.handle)
            return .persisted
        }
    }

    func rollback(
        reservation: ExtensionBridge.ExecutionReservation
    ) -> ExtensionBridge.StoreMutationResult {
        rollbackOwned(reservation: reservation, approved: false)
    }

    func rollback(permit: ExtensionBridge.ApprovedExecutionPermit) -> ExtensionBridge.StoreMutationResult {
        rollbackOwned(reservation: permit.reservation, approved: true)
    }

    private func rollbackOwned(
        reservation: ExtensionBridge.ExecutionReservation,
        approved: Bool
    ) -> ExtensionBridge.StoreMutationResult {
        files.withLock(or: .retryablePersistenceFailure) {
            guard reservation.authorization.isAuthorized == approved else { return .ownershipLost }
            let now = clock()
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: reservation.handle.profileIdentifier, now: now, recover: false
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.state.records.firstIndex(where: { $0.handle == reservation.handle }),
                  case .claimed(let claimID, _, _) = profile.state.records[index].state,
                  reservation.matches(handle: reservation.handle, value: claimID),
                  reservation.lease.isActive else { return .ownershipLost }
            return abandonClaimLocked(
                in: &profile, at: index, now: now, releaseLease: reservation.lease.release
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
        resolution: ImmediateResolution
    ) -> ExtensionBridge.StoreMutationResult {
        files.withLock(or: .retryablePersistenceFailure) {
            let now = clock()
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
            missing: .missing
        ) {
            readProfileFileLocked(
                at: files.profileURL(profileIdentifier),
                profileIdentifier: profileIdentifier,
                now: clock(), recover: false, normalizeDates: false, reconcileRevocations: false
            )
        }
    }

    private func readProfileFileLocked(
        at url: URL,
        profileIdentifier: UUID?,
        now: Date,
        recover: Bool,
        normalizeDates: Bool = true,
        reconcileRevocations: Bool = true
    ) -> ProfileRead {
        let ledger: WalletAuthorityRevocationLedger?
        if reconcileRevocations {
            guard let current = currentRevocationLedgerLocked() else { return .unavailable }
            ledger = current
        } else {
            ledger = nil
        }
        let data: Data
        switch files.readProfileDataLocked(at: url) {
        case .missing:
            guard let ledger else { return .missing }
            return .state(emptyProfile(profileIdentifier, revocationCursor: ledger.cursor))
        case .data(let storedData): data = storedData
        case .corrupt: return .corrupt
        case .unavailable: return .unavailable
        }
        guard let decoded = codec.decodeProfile(
            data, expectedIdentifier: profileIdentifier,
            recoverAuthority: recover, now: now
        ) else { return .corrupt }
        var profile = decoded.profile
        var changed = decoded.requiresAuthorityPublication
        var requiresReadBack = decoded.requiresAuthorityPublication
        if let ledger {
            guard let reconciled = profile.reconcileWalletAuthority(with: ledger, now: now) else {
                return .unavailable
            }
            changed = changed || reconciled
            requiresReadBack = requiresReadBack || reconciled
        }
        let normalizedDates = normalizeDates && profile.normalizeFutureDates(now: now)
        changed = changed || normalizedDates
        var locksToRemove = [ExtensionBridge.Handle]()
        if recover {
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

    struct ApprovalClaim: Equatable, Sendable {
        let handle: Handle
        let authority: ExecutionAuthority
        fileprivate let value: UUID
        fileprivate let lease: OperationLease

        var executionDeadline: Date { authority.executionDeadline }

        fileprivate init(handle: Handle, value: UUID, lease: OperationLease, authority: ExecutionAuthority) {
            self.handle = handle
            self.value = value
            self.lease = lease
            self.authority = authority
        }

        fileprivate func matches(handle: Handle, value: UUID) -> Bool {
            self.handle == handle && self.value == value
        }

        func releaseIfUnconsumed() { lease.releaseIfUnconsumed() }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.handle == rhs.handle && lhs.value == rhs.value && lhs.authority == rhs.authority
        }
    }

    fileprivate final class ReservationAuthorization: @unchecked Sendable {
        private let lock = NSLock()
        private var authorized = false

        var isAuthorized: Bool { lock.withLock { authorized } }

        func consume(lease: OperationLease) -> Bool {
            lock.withLock {
                guard !authorized, lease.isActive else { return false }
                authorized = true
                return true
            }
        }

        func releaseIfUnauthorized(_ lease: OperationLease) {
            lock.withLock {
                if !authorized { lease.release() }
            }
        }
    }

    struct ExecutionReservation: Equatable, @unchecked Sendable {
        let binding: RequestBinding
        let authority: ExecutionAuthority
        fileprivate let value: UUID
        fileprivate let lease: OperationLease
        fileprivate let authorization = ReservationAuthorization()
        fileprivate let nativeReceipt: NativeDeliveryReceipt?

        var handle: Handle { binding.handle }
        var request: SafariRequest { binding.request }
        var executionDeadline: Date { authority.executionDeadline }

        fileprivate init(claim: ApprovalClaim, record: ExtensionRequestProfile.Record, request: SafariRequest) {
            binding = .init(record: record, request: request)
            value = claim.value
            lease = claim.lease
            authority = claim.authority
            nativeReceipt = record.nativeDeliveryReceipt
        }

        fileprivate func matches(handle: Handle, value: UUID) -> Bool {
            self.handle == handle && self.value == value
        }

        func releaseLease() { authorization.releaseIfUnauthorized(lease) }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.binding == rhs.binding && lhs.value == rhs.value && lhs.authority == rhs.authority
        }
    }

    final class ApprovedExecutionPermit: Equatable, @unchecked Sendable {
        private enum State { case authorized, executing, checkpointed }
        private let lock = NSLock()
        private var state = State.authorized
        private var signingOperationIssued = false
        fileprivate let reservation: ExecutionReservation
        private let resolvedApproval: ResolvedDappApproval
        private let clock: () -> Date
        private weak var dispatchPermit: BroadcastDispatchPermit?
        let executionID = UUID()
        let signingDeadline: Date

        var handle: Handle { reservation.handle }
        var request: SafariRequest { reservation.request }
        var authority: ExecutionAuthority { reservation.authority }
        var executionDeadline: Date { reservation.executionDeadline }
        var approval: DappApprovalValidator.Approval { resolvedApproval.approval }

        fileprivate init(reservation: ExecutionReservation, approval: ResolvedDappApproval, clock: @escaping () -> Date) {
            self.reservation = reservation
            resolvedApproval = approval
            self.clock = clock
            let transaction: Bool
            switch reservation.request.body {
            case .ethereum(let body): transaction = body.method == .signTransaction
            case .solana(let body):
                transaction = body.method == .signTransaction || body.method == .signAllTransactions || body.method == .signAndSendTransaction
            case .unknown: transaction = false
            }
            if case .native = reservation.authority, transaction {
                signingDeadline = min(reservation.executionDeadline, approval.approvedAt.addingTimeInterval(ExtensionBridge.maximumTransactionDecisionAge))
            } else {
                signingDeadline = reservation.executionDeadline
            }
        }

        func consumeExecution() -> Bool {
            lock.withLock {
                guard case .authorized = state, reservation.lease.isActive, clock() < executionDeadline else { return false }
                state = .executing
                return true
            }
        }

        var isExecuting: Bool {
            lock.withLock {
                guard case .executing = state else { return false }
                return reservation.lease.isActive && clock() < executionDeadline
            }
        }

        func releaseLease() { reservation.lease.release() }

        func consumeSigningOperation() -> Bool {
            lock.withLock {
                guard !signingOperationIssued, reservation.lease.isActive, clock() < signingDeadline else { return false }
                switch state {
                case .authorized, .executing:
                    signingOperationIssued = true
                    return true
                case .checkpointed:
                    return false
                }
            }
        }

        var isSigningAuthorized: Bool {
            lock.withLock {
                guard case .executing = state else { return false }
                return reservation.lease.isActive && clock() < signingDeadline
            }
        }

        fileprivate func checkpoint(broadcast: PreparedBroadcast) -> BroadcastDispatchPermit? {
            lock.withLock {
                guard reservation.lease.isActive else { return nil }
                if case .checkpointed = state { return dispatchPermit }
                guard case .executing = state else { return nil }
                state = .checkpointed
                let dispatch = BroadcastDispatchPermit(broadcast: broadcast, approvedPermit: self)
                dispatchPermit = dispatch
                return dispatch
            }
        }

        fileprivate var canDispatch: Bool {
            lock.withLock {
                guard case .checkpointed = state else { return false }
                return reservation.lease.isActive
            }
        }

        deinit { reservation.lease.release() }

        static func == (lhs: ApprovedExecutionPermit, rhs: ApprovedExecutionPermit) -> Bool { lhs === rhs }
    }

    final class BroadcastDispatchPermit: Equatable, @unchecked Sendable {
        let broadcast: PreparedBroadcast
        let approvedPermit: ApprovedExecutionPermit
        private let lock = NSLock()
        private var consumed = false

        fileprivate init(broadcast: PreparedBroadcast, approvedPermit: ApprovedExecutionPermit) {
            self.broadcast = broadcast
            self.approvedPermit = approvedPermit
        }

        func consume() -> Bool {
            lock.withLock {
                guard !consumed, approvedPermit.canDispatch else { return false }
                consumed = true
                return true
            }
        }

        static func == (lhs: BroadcastDispatchPermit, rhs: BroadcastDispatchPermit) -> Bool { lhs === rhs }
    }
}
