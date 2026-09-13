// ∅ 2026 lil org

import Foundation

final class ExtensionRequestFileStore {
    typealias AtomicWrite = (Data, URL) throws -> Void
    typealias ReadData = (URL) throws -> Data
    typealias ReadFileSize = (URL) throws -> Int?
    typealias RemoveItem = (URL) throws -> Void
    typealias ParseRequest = (Data) -> SafariRequest?

    struct Dependencies {
        let clock: () -> Date
        let token: () -> UUID
        let crossProcessLock: CrossProcessFileLock?
        let crossProcessLockTimeoutNanoseconds: UInt64
        let crossProcessLockPollNanoseconds: UInt64
        let atomicWrite: AtomicWrite
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
            atomicWrite: @escaping AtomicWrite = ExtensionRequestFileStore.defaultAtomicWrite,
            readData: @escaping ReadData = ExtensionRequestFileStore.defaultReadData,
            readFileSize: @escaping ReadFileSize = ExtensionRequestFileStore.defaultReadFileSize,
            removeItem: @escaping RemoveItem = ExtensionRequestFileStore.defaultRemoveItem,
            parseRequest: @escaping ParseRequest = { SafariRequest(data: $0) }
        ) {
            self.clock = clock
            self.token = token
            self.crossProcessLock = crossProcessLock
            self.crossProcessLockTimeoutNanoseconds = crossProcessLockTimeoutNanoseconds
            self.crossProcessLockPollNanoseconds = crossProcessLockPollNanoseconds
            self.atomicWrite = atomicWrite
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
        var records: [Record]
    }

    private struct Record: Codable {
        struct StagedApproval: Codable {
            let decision: Data
            let stagedAt: Date
            var receipt: ExtensionBridge.NativeDeliveryReceipt?
        }

        enum PendingApproval: Codable {
            case unowned
            case delivered(ExtensionBridge.NativeDeliveryReceipt)
            case staged(StagedApproval, context: ExtensionBridge.NativeExecutionContext?)

            func replacingReceipt(
                _ receipt: ExtensionBridge.NativeDeliveryReceipt?
            ) -> Self {
                switch self {
                case .unowned, .delivered:
                    return receipt.map(Self.delivered) ?? .unowned
                case .staged(var approval, let context):
                    approval.receipt = receipt
                    return .staged(approval, context: context)
                }
            }
        }

        enum ClaimedApproval: Codable {
            case ordinary
            case native(StagedApproval, context: ExtensionBridge.NativeExecutionContext)

            var pending: PendingApproval {
                switch self {
                case .ordinary:
                    return .unowned
                case .native(let approval, let context):
                    return .staged(approval, context: context)
                }
            }

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
            case native(StagedApproval)
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
        let revisions: ExtensionBridge.ProviderRevisions
        let admissionCreatedAt: Date
        var createdAt: Date
        var state: State
        let nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce

        var stagedApproval: StagedApproval? {
            switch state {
            case .pending(_, .staged(let approval, _)),
                 .claimed(_, _, .native(let approval, _)),
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
            return stagedApproval?.receipt
        }

        var nativeExecutionContext: ExtensionBridge.NativeExecutionContext? {
            switch state {
            case .pending(_, .staged(_, let context)):
                return context
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
            guard case .claimed(_, let request, let approval) = state else {
                return false
            }
            state = .pending(request: request, approval: approval.pending)
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
        case state(ProfileState)
        case corrupt
        case unavailable
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

    private struct ProfileFileIdentity {
        let identifier: UUID?
    }

    private struct ProfileFileCandidate {
        let url: URL
        let identity: ProfileFileIdentity
    }

    private struct ManualSwitchCursor: Codable {
        let version: Int
        let profile: String
        let admittedAt: Date
        let requestToken: String

        init(record: Record) {
            version = 1
            profile = record.profileIdentifier?.uuidString.lowercased() ?? "default"
            admittedAt = record.admissionCreatedAt
            requestToken = record.handle.requestToken
        }

        static func decode(_ value: String, profileIdentifier: UUID?) -> Self? {
            guard value.utf8.count <= 1024,
                  let data = Data(base64Encoded: value),
                  data.base64EncodedString() == value,
                  let cursor = try? JSONDecoder().decode(Self.self, from: data),
                  cursor.version == 1,
                  cursor.profile == (profileIdentifier?.uuidString.lowercased() ?? "default"),
                  cursor.admittedAt.timeIntervalSinceReferenceDate.isFinite,
                  ExtensionBridge.lowercaseUUID(cursor.requestToken) != nil,
                  cursor.encoded == value else { return nil }
            return cursor
        }

        var encoded: String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(self))?.base64EncodedString()
        }

        func precedes(_ record: Record) -> Bool {
            admittedAt < record.admissionCreatedAt ||
                (admittedAt == record.admissionCreatedAt &&
                    requestToken < record.handle.requestToken)
        }
    }

    private static let profileSchemaVersion = 7
    private static let profileDirectoryName = "profiles-v7"
    private static let profileSweepCursorName = "sweep.cursor"
    private static let operationLockDirectoryName = "operation-locks-v7"
    private static let nativeExecutionFenceDirectoryName =
        "native-execution-fences-v7"
    static let profileSweepBatchSize = 2
    private static let maximumProfileBytes =
        ExtensionBridge.maximumRetainedBytes + 64 * 1024
    private static let futureSkew = ExtensionBridge.admissionDeadlineFutureSkew

    private let rootURL: URL?
    private let clock: () -> Date
    private let token: () -> UUID
    private let storeLock: CrossProcessFileLock?
    private let lockTimeout: UInt64
    private let lockPoll: UInt64
    private let atomicWrite: AtomicWrite
    private let readData: ReadData
    private let readFileSize: ReadFileSize
    private let removeItem: RemoveItem
    private let parseRequest: ParseRequest
    private let fileManager = FileManager.default

    static func defaultAtomicWrite(_ data: Data, _ url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

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

    init(
        rootURL: URL?,
        dependencies: Dependencies = .init()
    ) {
        self.rootURL = rootURL
        clock = dependencies.clock
        token = dependencies.token
        lockTimeout = dependencies.crossProcessLockTimeoutNanoseconds
        lockPoll = dependencies.crossProcessLockPollNanoseconds
        atomicWrite = dependencies.atomicWrite
        readData = dependencies.readData
        readFileSize = dependencies.readFileSize
        removeItem = dependencies.removeItem
        parseRequest = dependencies.parseRequest
        storeLock = dependencies.crossProcessLock ?? rootURL.map {
            CrossProcessFileLock(fileURL: $0.appendingPathComponent("bridge-v7.lock"))
        }
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

            if let existing = profile.records.first(where: {
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
                return .accepted(
                    handle: existing.handle,
                    approvalRequired: approvalRequired,
                    revisions: existing.revisions,
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

            if ingress.request.name == "switchAccount",
               ingress.request.provider == .unknown,
               let existing = profile.records.first(where: { record in
                   record.configurationKey == ingress.request.configurationKey &&
                       !record.responseAcknowledged && isManualSwitch(record)
               }) {
                return .accepted(
                    handle: existing.handle,
                    approvalRequired: existing.state.isActive,
                    revisions: existing.revisions,
                    admissionKind: .coalesced,
                    nativeDeliveryNonce: existing.nativeDeliveryNonce
                )
            }

            let active = profile.records.filter(\.state.isActive)
            guard active.count < ExtensionBridge.maximumRequests,
                  active.filter({
                      $0.configurationKey == ingress.request.configurationKey
                  }).count <
                    ExtensionBridge.maximumRequestsPerHost,
                  let requestToken = uniqueToken(in: profile.records),
                  let nativeDeliveryNonceValue = uniqueToken(
                    in: profile.records,
                    excluding: requestToken
                  ) else {
                return .rejected
            }

            let record = Record(
                id: ingress.request.id,
                profileIdentifier: profileIdentifier,
                enqueueAttempt: ingress.request.enqueueAttempt,
                requestToken: requestToken,
                host: ingress.request.host,
                configurationKey: ingress.request.configurationKey,
                requestFingerprint: ingress.fingerprint,
                revisions: ingress.revisions,
                admissionCreatedAt: now,
                createdAt: now,
                state: .pending(request: ingress.canonicalData, approval: .unowned),
                nativeDeliveryNonce: .init(value: nativeDeliveryNonceValue)
            )
            guard let retiredHandles = makeRoomForAdmission(
                record,
                in: &profile.records,
                now: now
            ) else { return .rejected }
            profile.records.append(record)
            guard writeProfileLocked(profile) ||
                    verifyNewAdmissionLocked(record) else {
                return .unavailable
            }
            for handle in retiredHandles {
                removeOperationLockLocked(handle: handle)
                removeNativeExecutionFenceLocked(handle: handle)
            }
            return .accepted(
                handle: record.handle,
                approvalRequired: true,
                revisions: record.revisions,
                admissionKind: .new,
                nativeDeliveryNonce: record.nativeDeliveryNonce
            )
        }
    }

    private func verifyNewAdmissionLocked(_ expected: Record) -> Bool {
        guard let stored = persistedRecordLocked(handle: expected.handle),
              stored.id == expected.id,
              stored.profileIdentifier == expected.profileIdentifier,
              stored.enqueueAttempt == expected.enqueueAttempt,
              stored.host == expected.host,
              stored.configurationKey == expected.configurationKey,
              stored.requestFingerprint == expected.requestFingerprint,
              stored.revisions == expected.revisions,
              stored.admissionCreatedAt == expected.admissionCreatedAt,
              stored.createdAt == expected.createdAt,
              stored.nativeDeliveryNonce == expected.nativeDeliveryNonce,
              case .pending(let storedRequest, .unowned) = stored.state,
              case .pending(let expectedRequest, .unowned) = expected.state else {
            return false
        }
        return storedRequest == expectedRequest
    }

    func list(profileIdentifier: UUID?) -> ExtensionBridge.SnapshotsResult {
        let maintenanceCandidates = discoverProfileCandidates(
            excluding: profileIdentifier
        )
        return withLock(or: .unavailable) {
            let now = clock()
            guard prepareDirectoriesLocked() else { return .unavailable }
            sweepProfilesLocked(
                candidates: maintenanceCandidates,
                now: now
            )
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: profileIdentifier,
                now: now,
                recover: true
            ) else { return .unavailable }
            let completedCount = max(
                0,
                ExtensionBridge.maximumRetainedRequests -
                    profile.records.filter(\.state.isActive).count
            )
            let completedHandles = Set(profile.records.filter {
                !$0.state.isActive && !$0.responseAcknowledged
            }.prefix(completedCount).map(\.handle))
            let snapshots = profile.records.enumerated().reduce(
                into: [ExtensionBridge.Handle: ExtensionBridge.Snapshot]()
            ) { result, item in
                guard item.element.state.isActive ||
                    completedHandles.contains(item.element.handle) else { return }
                result[item.element.handle] = snapshot(
                    item.element,
                    sequence: item.offset
                )
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
            guard let index = profile.records.firstIndex(where: {
                $0.handle == handle
            }) else {
                return .missing
            }
            return .found(snapshot(profile.records[index], sequence: index))
        }
    }

    func listManualSwitchRequests(
        profileIdentifier: UUID?,
        cursor: String?
    ) -> ExtensionBridge.ManualSwitchRequestsResult {
        let position: ManualSwitchCursor?
        if let cursor {
            guard let decoded = ManualSwitchCursor.decode(
                cursor,
                profileIdentifier: profileIdentifier
            ) else { return .invalidCursor }
            position = decoded
        } else {
            position = nil
        }
        return withLock(or: .unavailable) {
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .unavailable }
            let records = profile.records.filter {
                !$0.responseAcknowledged && isManualSwitch($0) &&
                    (position?.precedes($0) ?? true)
            }.sorted {
                $0.admissionCreatedAt == $1.admissionCreatedAt
                    ? $0.handle.requestToken < $1.handle.requestToken
                    : $0.admissionCreatedAt < $1.admissionCreatedAt
            }
            var requests = [ExtensionBridge.ManualSwitchRequest]()
            var lastCursor: String?
            for record in records.prefix(ExtensionBridge.maximumRetainedRequests) {
                guard let cursor = ManualSwitchCursor(record: record).encoded else {
                    return .unavailable
                }
                let candidate = requests + [manualSwitchRequest(record)]
                guard let data = ExtensionBridge.payloadData([
                    "requests": candidate.map(\.json),
                    "nextCursor": cursor,
                ]), data.count <= ExtensionBridge.maximumManualSwitchPageBytes - 1024 else {
                    guard !requests.isEmpty else { return .unavailable }
                    break
                }
                requests = candidate
                lastCursor = cursor
            }
            return .available(.init(
                requests: requests,
                nextCursor: requests.count < records.count ? lastCursor : nil
            ))
        }
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
            guard let index = profile.records.firstIndex(where: {
                $0.handle == handle && $0.configurationKey == configurationKey &&
                    !$0.responseAcknowledged && isManualSwitch($0)
            }) else { return .missing }
            return .found(snapshot(profile.records[index], sequence: index))
        }
    }

    private func isManualSwitch(_ record: Record) -> Bool {
        if let request = record.state.requestData.flatMap(parseRequest) {
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
            state = record.stagedApproval == nil ? .pending : .approved
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
            guard let index = profile.records.firstIndex(where: { $0.handle == handle }) else {
                return .missing
            }
            switch profile.records[index].state {
            case .pending(let request, let approval):
                guard case .unowned = approval else {
                    return .executing
                }
                guard let lease = acquireOperationLeaseLocked(handle: handle),
                      let claimID = nextID(excluding: handle.token.value) else {
                    return .unavailable
                }
                profile.records[index].state = .claimed(
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
                    lease: lease
                ))
            case .claimed, .broadcastPrepared:
                return .executing
            case .completed:
                return .responded
            }
        }
    }

    func stageNativeDecision(
        handle: ExtensionBridge.Handle,
        decision: NativeApprovalDecision
    ) -> ExtensionBridge.StoreMutationResult {
        stageNativeDecision(
            handle: handle,
            expectedReceipt: nil,
            decision: decision
        )
    }

    func stageNativeDecision(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        decision: NativeApprovalDecision
    ) -> ExtensionBridge.StoreMutationResult {
        stageNativeDecision(
            handle: handle,
            expectedReceipt: .init(
                nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtimeInstanceIdentifier
            ),
            decision: decision
        )
    }

    private func stageNativeDecision(
        handle: ExtensionBridge.Handle,
        expectedReceipt: ReceiptIdentity?,
        decision: NativeApprovalDecision
    ) -> ExtensionBridge.StoreMutationResult {
        guard let decisionData = decision.boundedData else {
            return .ownershipLost
        }
        return withLock(or: .retryablePersistenceFailure) {
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.records.firstIndex(where: {
                $0.handle == handle
            }), case .pending(let request, _) = profile.records[index].state,
                  receiptMatches(
                    profile.records[index].nativeDeliveryReceipt,
                    expected: expectedReceipt
                  ) else {
                return .ownershipLost
            }
            if let existing = profile.records[index].stagedApproval {
                return NativeApprovalDecision.decodeBounded(existing.decision) == decision
                    ? .persisted
                    : .ownershipLost
            }
            let stagedApproval = Record.StagedApproval(
                decision: decisionData,
                stagedAt: max(profile.records[index].createdAt, clock()),
                receipt: profile.records[index].nativeDeliveryReceipt
            )
            profile.records[index].state = .pending(
                request: request,
                approval: .staged(stagedApproval, context: nil)
            )
            return writeProfileLocked(profile) ||
                verifyNativeDecisionLocked(
                    handle: handle,
                    expectedReceipt: expectedReceipt,
                    expectedDecision: decisionData
                ) ? .persisted : .retryablePersistenceFailure
        }
    }

    private func verifyNativeDecisionLocked(
        handle: ExtensionBridge.Handle,
        expectedReceipt: ReceiptIdentity?,
        expectedDecision: Data
    ) -> Bool {
        guard let record = persistedRecordLocked(handle: handle),
              case .pending = record.state,
              receiptMatches(
                record.nativeDeliveryReceipt,
                expected: expectedReceipt
              ),
              record.stagedApproval?.decision == expectedDecision else {
            return false
        }
        return true
    }

    func recordNativeDeliveryReceipt(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        owner: ExtensionBridge.NativeDeliveryOwner
    ) -> ExtensionBridge.StoreMutationResult {
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtimeInstanceIdentifier,
            owner: owner
        )
        return withLock(or: .retryablePersistenceFailure) {
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.records.firstIndex(where: {
                $0.handle == handle
            }), case .pending(let request, let approval) = profile.records[index].state,
                  profile.records[index].nativeDeliveryNonce ==
                    nativeDeliveryNonce else {
                return .ownershipLost
            }
            if let existing = profile.records[index].nativeDeliveryReceipt {
                return existing == receipt ? .persisted : .ownershipLost
            }
            profile.records[index].state = .pending(
                request: request,
                approval: approval.replacingReceipt(receipt)
            )
            return writeProfileLocked(profile) ||
                verifyNativeDeliveryReceiptLocked(
                    handle: handle,
                    expected: receipt
                ) ? .persisted : .retryablePersistenceFailure
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
            guard let index = profile.records.firstIndex(where: {
                $0.handle == handle
            }), case .pending(let request, let approval) = profile.records[index].state,
                  profile.records[index].nativeDeliveryNonce ==
                    nativeDeliveryNonce else {
                return .ownershipLost
            }
            guard let existing = profile.records[index].nativeDeliveryReceipt else {
                return .persisted
            }
            guard existing.nativeDeliveryNonce == nativeDeliveryNonce,
                  existing.runtimeInstanceIdentifier ==
                    runtimeInstanceIdentifier else {
                return .ownershipLost
            }
            profile.records[index].state = .pending(
                request: request,
                approval: approval.replacingReceipt(nil)
            )
            return writeProfileLocked(profile) ||
                verifyNativeDeliveryReceiptLocked(
                    handle: handle,
                    expected: nil
                ) ? .persisted : .retryablePersistenceFailure
        }
    }

    private func verifyNativeDeliveryReceiptLocked(
        handle: ExtensionBridge.Handle,
        expected: ExtensionBridge.NativeDeliveryReceipt?
    ) -> Bool {
        guard let record = persistedRecordLocked(handle: handle),
              case .pending = record.state else {
            return false
        }
        return record.nativeDeliveryReceipt == expected
    }

    func claimExecutableNativeDecision(
        handle: ExtensionBridge.Handle
    ) -> ExtensionBridge.NativeDecisionClaimResult {
        withLock(or: .unavailable) {
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .unavailable }
            guard let index = profile.records.firstIndex(where: {
                $0.handle == handle
            }) else { return .missing }
            switch profile.records[index].state {
            case .pending(let request, let pendingApproval):
                guard case .staged(let approval, let context) = pendingApproval,
                      let decision = NativeApprovalDecision.decodeBounded(
                          approval.decision
                      ) else { return .notStaged }
                guard let executionContext = context,
                      nativeExecutionFenceIsHeldLocked(
                          handle: handle,
                          token: executionContext.fenceToken
                      ) else { return .notStaged }
                guard let lease = acquireOperationLeaseLocked(handle: handle),
                      let claimID = nextID(excluding: handle.token.value) else {
                    return .unavailable
                }
                profile.records[index].state = .claimed(
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
                    lease: lease
                )
                return .claimed(.init(
                    approvalClaim: claim,
                    decision: decision,
                    stagedAt: approval.stagedAt,
                    executionContext: executionContext
                ))
            case .claimed, .broadcastPrepared:
                return .executing
            case .completed:
                return .responded
            }
        }
    }

    func acquireNativeExecutionFence(
        handle: ExtensionBridge.Handle,
        token: UUID
    ) -> ExtensionBridge.NativeExecutionFence? {
        guard let storeLock else { return nil }
        return withLock(or: nil) {
            guard prepareDirectoriesLocked(),
                  case .state(let profile) = readProfileLocked(
                      profileIdentifier: handle.profileIdentifier,
                      now: clock(),
                      recover: true
                  ), let record = profile.records.first(where: {
                      $0.handle == handle
                  }), record.state.isActive else { return nil }
            let url = nativeExecutionFenceURL(handle)
            let ownerURL = nativeExecutionFenceOwnerURL(handle)
            switch regularFileStatusLocked(at: url) {
            case .missing, .regular:
                break
            case .unsafe, .unavailable:
                return nil
            }
            switch regularFileStatusLocked(at: ownerURL) {
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
                try Data(token.uuidString.lowercased().utf8).write(
                    to: ownerURL,
                    options: .atomic
                )
                return .init(
                    fileURL: url,
                    token: token,
                    lock: lock,
                    coordinationLock: storeLock,
                    coordinationPollNanoseconds: lockPoll
                )
            } catch {
                lock.release()
                return nil
            }
        }
    }

    func nativeExecutionFenceIsHeld(
        handle: ExtensionBridge.Handle,
        token: UUID
    ) -> Bool {
        withLock(or: false) {
            nativeExecutionFenceIsHeldLocked(handle: handle, token: token)
        }
    }

    func recordNativeExecutionContext(
        handle: ExtensionBridge.Handle,
        configurationKey: String,
        revisions: ExtensionBridge.ProviderRevisions,
        executionDeadline: Date,
        fenceToken: UUID
    ) -> ExtensionBridge.NativeExecutionContextResult {
        withLock(or: .unavailable) {
            let now = clock()
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: now,
                recover: true
            ) else { return .unavailable }
            guard let index = profile.records.firstIndex(where: {
                $0.handle == handle
            }) else { return .missing }
            let record = profile.records[index]
            guard record.configurationKey == configurationKey else {
                return .missing
            }
            switch record.state {
            case .completed:
                return .responseReady
            case .claimed, .broadcastPrepared:
                return record.nativeExecutionContext.map {
                    .recorded($0)
                } ?? .pending
            case .pending(let request, let pendingApproval):
                guard case .staged(let approval, _) = pendingApproval else {
                    return .pending
                }
                guard nativeExecutionFenceIsHeldLocked(
                    handle: handle,
                    token: fenceToken
                ) else { return .unavailable }
                let observedAt = max(approval.stagedAt, now)
                guard executionDeadline >= observedAt,
                      executionDeadline <= now.addingTimeInterval(
                          ExtensionBridge.nativeExecutionTimeout +
                            Self.futureSkew
                      ) else { return .unavailable }
                let context = ExtensionBridge.NativeExecutionContext(
                    revisions: revisions,
                    observedAt: observedAt,
                    executionDeadline: executionDeadline,
                    fenceToken: fenceToken
                )
                profile.records[index].state = .pending(
                    request: request,
                    approval: .staged(approval, context: context)
                )
                return writeProfileLocked(profile) ||
                    verifyNativeExecutionContextLocked(
                        handle: handle,
                        expected: context
                    ) ? .recorded(context) : .unavailable
            }
        }
    }

    func clearNativeExecutionContext(
        handle: ExtensionBridge.Handle,
        expected: ExtensionBridge.NativeExecutionContext
    ) -> ExtensionBridge.StoreMutationResult {
        withLock(or: .retryablePersistenceFailure) {
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.records.firstIndex(where: {
                $0.handle == handle
            }), case .pending(let request, .staged(let approval, let context)) =
                    profile.records[index].state else {
                return .ownershipLost
            }
            guard let existing = context else {
                return .persisted
            }
            guard existing == expected else { return .ownershipLost }
            profile.records[index].state = .pending(
                request: request,
                approval: .staged(approval, context: nil)
            )
            return writeProfileLocked(profile) ||
                verifyNativeExecutionContextLocked(
                    handle: handle,
                    expected: nil
                ) ? .persisted : .retryablePersistenceFailure
        }
    }

    private func verifyNativeExecutionContextLocked(
        handle: ExtensionBridge.Handle,
        expected: ExtensionBridge.NativeExecutionContext?
    ) -> Bool {
        guard let record = persistedRecordLocked(handle: handle),
              case .pending(_, .staged) = record.state else {
            return false
        }
        return record.nativeExecutionContext == expected
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
            guard let index = profile.records.firstIndex(where: {
                $0.handle == claim.handle
            }), case .claimed(let claimID, _, _) = profile.records[index].state,
                  claim.matches(handle: claim.handle, value: claimID) else {
                return .ownershipLost
            }
            profile.records[index].restorePendingClaim()
            let result: ExtensionBridge.StoreMutationResult
            switch transitionExpiredPending(
                &profile.records[index],
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
            claim.releaseLease()
            removeOperationLockLocked(handle: claim.handle)
            removeNativeExecutionFenceLocked(handle: claim.handle)
            return result
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
            guard let index = profile.records.firstIndex(where: { $0.handle == handle }),
                  let requestData = profile.records[index].state.requestData,
                  let request = parseRequest(requestData),
                  case .pending = profile.records[index].state,
                  profile.records[index].stagedApproval == nil,
                  receiptMatches(
                    profile.records[index].nativeDeliveryReceipt,
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
            profile.records[index].complete(response: data, at: now)
            return writeProfileLocked(profile) ||
                verifyCompletionLocked(
                    handle: handle,
                    expectedResponse: data
                ) ? .persisted : .retryablePersistenceFailure
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
            guard let record = profile.records.first(where: {
                $0.handle == claim.handle
            }), case .claimed(let claimID, _, _) = record.state,
                  claim.matches(handle: claim.handle, value: claimID),
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
            guard let index = profile.records.firstIndex(where: {
                $0.handle == permit.handle
            }) else { return .ownershipLost }
            switch profile.records[index].state {
            case .claimed(let claimID, let request, let approval):
                let authorizationTime = clock()
                guard permit.matches(handle: permit.handle, value: claimID),
                      permit.lease != nil,
                      executionAuthorityAuthorizesLocked(
                          record: profile.records[index],
                          authority: authority,
                          now: authorizationTime
                      ) else { return .ownershipLost }
                profile.records[index].state = .broadcastPrepared(
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
                return existing == responseData ? .persisted : .ownershipLost
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
            guard let index = profile.records.firstIndex(where: {
                $0.handle == permit.handle
            }) else { return .ownershipLost }
            let requestData: Data
            let claimID: UUID
            let recoveryResponseData: Data?
            switch profile.records[index].state {
            case .claimed(let value, let request, _):
                claimID = value
                requestData = request
                recoveryResponseData = nil
            case .broadcastPrepared(let value, let request, let recoveryResponse, _):
                claimID = value
                requestData = request
                recoveryResponseData = recoveryResponse
            case .completed:
                permit.releaseLease()
                return .persisted
            case .pending:
                return .ownershipLost
            }
            let authorizationTime = clock()
            guard permit.matches(handle: permit.handle, value: claimID),
                  executionAuthorityAuthorizesLocked(
                      record: profile.records[index],
                      authority: authority,
                      now: authorizationTime
                  ),
                  let request = parseRequest(requestData),
                  let responseData = boundedResponseData(
                      response,
                      request: request,
                      recoveryResponseData: recoveryResponseData
                  ) else {
                return .ownershipLost
            }
            profile.records[index].complete(
                response: responseData,
                at: authorizationTime
            )
            guard writeProfileLocked(profile) else {
                return .retryablePersistenceFailure
            }
            permit.releaseLease()
            removeOperationLockLocked(handle: permit.handle)
            removeNativeExecutionFenceLocked(handle: permit.handle)
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
            guard let index = profile.records.firstIndex(where: {
                $0.handle == permit.handle
            }), case .claimed(let claimID, _, _) =
                    profile.records[index].state,
                  permit.matches(handle: permit.handle, value: claimID),
                  permit.lease != nil else { return .ownershipLost }
            profile.records[index].restorePendingClaim()
            let result: ExtensionBridge.StoreMutationResult
            switch transitionExpiredPending(
                &profile.records[index],
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
            permit.releaseLease()
            removeOperationLockLocked(handle: permit.handle)
            removeNativeExecutionFenceLocked(handle: permit.handle)
            return result
        }
    }

    func readResponse(
        handle: ExtensionBridge.Handle,
        configurationKey: String
    ) -> ExtensionBridge.ResponseReadResult {
        withLock(or: .unavailable) {
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .unavailable }
            guard let record = profile.records.first(where: { $0.handle == handle }),
                  record.configurationKey == configurationKey else { return .missing }
            switch record.state {
            case .pending, .claimed, .broadcastPrepared:
                return .pending
            case .completed(_, let responseData, _):
                guard let response = responseJSON(responseData, id: handle.id) else {
                    return .unavailable
                }
                return .response(response)
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
            guard let index = profile.records.firstIndex(where: {
                $0.handle == handle && $0.configurationKey == configurationKey
            }) else { return .ownershipLost }
            guard case .completed(let since, let response, let acknowledged) =
                    profile.records[index].state else {
                return .retryablePersistenceFailure
            }
            if acknowledged {
                return .persisted
            }
            profile.records[index].state = .completed(
                since: since,
                response: response,
                acknowledged: true
            )
            return writeProfileLocked(profile) ||
                verifyResponseAcknowledgmentLocked(
                    handle: handle,
                    configurationKey: configurationKey
                ) ? .persisted : .retryablePersistenceFailure
        }
    }

    private func verifyResponseAcknowledgmentLocked(
        handle: ExtensionBridge.Handle,
        configurationKey: String
    ) -> Bool {
        guard let record = persistedRecordLocked(handle: handle),
              record.configurationKey == configurationKey,
              case .completed = record.state else { return false }
        return record.responseAcknowledged
    }

    private func finish(
        handle: ExtensionBridge.Handle,
        expectedReceipt: ReceiptIdentity?,
        response: ResponseToExtension
    ) -> ExtensionBridge.StoreMutationResult {
        withLock(or: .retryablePersistenceFailure) {
            let now = clock()
            guard response.id == handle.id,
                  case .state(var profile) = readProfileLocked(
                    profileIdentifier: handle.profileIdentifier,
                    now: now,
                    recover: false
                  ),
                  let index = profile.records.firstIndex(where: { $0.handle == handle }) else {
                return .ownershipLost
            }
            guard case .pending = profile.records[index].state,
                  profile.records[index].stagedApproval == nil,
                  receiptMatches(
                    profile.records[index].nativeDeliveryReceipt,
                    expected: expectedReceipt
                  ) else {
                return .ownershipLost
            }
            let request: SafariRequest
            switch transitionExpiredPending(
                &profile.records[index],
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
            profile.records[index].complete(response: responseData, at: now)
            return writeProfileLocked(profile) ||
                verifyCompletionLocked(
                    handle: handle,
                    expectedResponse: responseData
                ) ? .persisted : .retryablePersistenceFailure
        }
    }

    private func verifyCompletionLocked(
        handle: ExtensionBridge.Handle,
        expectedResponse: Data
    ) -> Bool {
        guard let record = persistedRecordLocked(handle: handle),
              case .completed(_, let response, _) = record.state,
              response == expectedResponse else {
            return false
        }
        return true
    }

    private func persistedRecordLocked(
        handle: ExtensionBridge.Handle
    ) -> Record? {
        guard case .state(let profile) = readProfileLocked(
            profileIdentifier: handle.profileIdentifier,
            now: clock(),
            recover: false
        ) else { return nil }
        return profile.records.first { $0.handle == handle }
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
            recover: recover,
            removeIfEmpty: false
        )
    }

    private func readProfileFileLocked(
        at url: URL,
        profileIdentifier: UUID?,
        now: Date,
        recover: Bool,
        removeIfEmpty: Bool
    ) -> ProfileRead {
        let data: Data
        switch regularFileStatusLocked(at: url) {
        case .missing:
            return .state(emptyProfile(profileIdentifier))
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
            data = try readData(url)
        } catch {
            return .unavailable
        }
        guard data.count <= Self.maximumProfileBytes,
              var profile = try? PropertyListDecoder().decode(ProfileState.self, from: data),
              validate(
                  profile,
                  expectedIdentifier: profileIdentifier
              ) else {
            return .corrupt
        }
        let normalizedDates = normalizeFutureDates(in: &profile, now: now)
        guard recover else { return .state(profile) }
        var changed = normalizedDates
        var locksToRemove = [ExtensionBridge.Handle]()
        var kept = [Record]()
        for var record in profile.records {
            switch record.state {
            case .claimed:
                switch operationLockStatusLocked(handle: record.handle) {
                case .held, .unsafe, .unavailable:
                    break
                case .unlocked:
                    record.restorePendingClaim()
                    changed = true
                    locksToRemove.append(record.handle)
                }
            case .broadcastPrepared(_, _, let recoveryResponse, _):
                switch operationLockStatusLocked(handle: record.handle) {
                case .held, .unsafe, .unavailable:
                    break
                case .unlocked:
                    record.complete(response: recoveryResponse, at: now)
                    changed = true
                    locksToRemove.append(record.handle)
                }
            case .pending, .completed:
                break
            }
            switch record.state {
            case .pending:
                switch transitionExpiredPending(&record, now: now) {
                case .active:
                    break
                case .expired:
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
                    changed = true
                    locksToRemove.append(record.handle)
                } else {
                    kept.append(record)
                }
            case .claimed, .broadcastPrepared:
                kept.append(record)
            }
        }
        guard changed else {
            if removeIfEmpty, profile.records.isEmpty,
               !removeProfileFileLocked(at: url) {
                return .unavailable
            }
            return .state(profile)
        }
        profile.records = kept
        if removeIfEmpty, profile.records.isEmpty {
            guard removeProfileFileLocked(at: url) else { return .unavailable }
        } else {
            guard writeProfileLocked(profile) else { return .unavailable }
        }
        for handle in locksToRemove {
            removeOperationLockLocked(handle: handle)
            removeNativeExecutionFenceLocked(handle: handle)
        }
        return .state(profile)
    }

    private func discoverProfileCandidates(
        excluding profileIdentifier: UUID?
    ) -> [ProfileFileCandidate] {
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
                guard let identity = profileFileIdentity(for: url),
                      identity.identifier != profileIdentifier else { return nil }
                return ProfileFileCandidate(url: url, identity: identity)
            }.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        } catch {
            return []
        }
    }

    private func sweepProfilesLocked(
        candidates: [ProfileFileCandidate],
        now: Date
    ) {
        let profileSweepCursor = readProfileSweepCursorLocked()
        var startIndex = 0
        if let profileSweepCursor {
            startIndex = candidates.firstIndex(where: {
                $0.url.lastPathComponent > profileSweepCursor
            }) ?? 0
        }
        let selectedCount = min(Self.profileSweepBatchSize, candidates.count)
        let selected = (0..<selectedCount).map {
            candidates[(startIndex + $0) % candidates.count]
        }
        for candidate in selected {
            guard let identity = profileFileIdentity(for: candidate.url),
                  identity.identifier == candidate.identity.identifier else {
                continue
            }
            _ = readProfileFileLocked(
                at: candidate.url,
                profileIdentifier: candidate.identity.identifier,
                now: now,
                recover: true,
                removeIfEmpty: true
            )
        }
        if let last = selected.last {
            persistProfileSweepCursorLocked(last.url.lastPathComponent)
        }
    }

    private func readProfileSweepCursorLocked() -> String? {
        switch regularFileStatusLocked(at: profileSweepCursorURL) {
        case .regular:
            break
        case .missing, .unsafe, .unavailable:
            return nil
        }
        let data: Data
        do {
            guard let size = try readFileSize(profileSweepCursorURL),
                  size > 0, size <= 64 else { return nil }
            data = try readData(profileSweepCursorURL)
            guard data.count == size else { return nil }
        } catch {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8),
              value == URL(fileURLWithPath: value).lastPathComponent,
              profileFileIdentity(
                for: profileDirectoryURL.appendingPathComponent(value)
              ) != nil else { return nil }
        return value
    }

    private func persistProfileSweepCursorLocked(_ value: String) {
        switch regularFileStatusLocked(at: profileSweepCursorURL) {
        case .missing, .regular:
            break
        case .unsafe, .unavailable:
            return
        }
        guard let data = value.data(using: .utf8),
              data.count <= 64 else { return }
        try? atomicWrite(data, profileSweepCursorURL)
    }

    private func expirationResponseData(for request: SafariRequest) -> Data? {
        boundedResponseData(
            ResponseToExtension(for: request, payload: .error(.userRejected)),
            request: request
        )
    }

    private func transitionExpiredPending(
        _ record: inout Record,
        now: Date
    ) -> PendingDeadlineTransition {
        guard case .pending(let requestData, _) = record.state,
              let request = parseRequest(requestData) else {
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

    private func validate(
        _ profile: ProfileState,
        expectedIdentifier: UUID?
    ) -> Bool {
        let active = profile.records.filter(\.state.isActive)
        guard profile.schemaVersion == Self.profileSchemaVersion,
              profile.workflowVersion == ExtensionBridge.workflowVersion,
              profile.profileIdentifier == expectedIdentifier,
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
            return false
        }
        return profile.records.allSatisfy { record in
            guard record.profileIdentifier == expectedIdentifier,
                  !record.host.isEmpty,
                  ExtensionBridge.ProviderRevisions(
                      rawValue: record.revisions.json
                  ) != nil,
                  ExtensionBridge.isValidIdentity(
                      host: record.host,
                      configurationKey: record.configurationKey
                  ),
                  ExtensionBridge.isValidEnqueueAttempt(record.enqueueAttempt),
                  record.createdAt <= record.admissionCreatedAt,
                  record.stagedApproval.map({
                      NativeApprovalDecision.decodeBounded($0.decision) != nil &&
                        $0.stagedAt >= record.createdAt
                  }) ?? true,
                  record.nativeExecutionContext.map({ context in
                      record.stagedApproval.map {
                            context.observedAt >= $0.stagedAt
                      } == true &&
                        context.executionDeadline >= context.observedAt &&
                        ExtensionBridge.ProviderRevisions(
                            rawValue: context.revisions.json
                        ) != nil
                  }) ?? true,
                  record.nativeDeliveryReceipt.map({
                      $0.nativeDeliveryNonce == record.nativeDeliveryNonce &&
                        $0.owner.isValid
                  }) ?? true else {
                return false
            }
            if let requestData = record.state.requestData {
                guard requestData.count <= ExtensionBridge.maximumPayloadBytes,
                      let rawObject = try? JSONSerialization.jsonObject(
                          with: requestData
                      ) as? [String: Any],
                      ExtensionBridge.ProviderRevisions(
                          rawValue: rawObject["revisions"]
                      ) == record.revisions,
                      ExtensionBridge.correlationFingerprint(rawObject) ==
                        record.requestFingerprint,
                      let request = parseRequest(requestData),
                      request.id == record.id,
                      request.host == record.host,
                      request.configurationKey == record.configurationKey,
                      request.enqueueAttempt == record.enqueueAttempt,
                      ExtensionBridge.admissionDeadlineDisposition(
                          request.admissionDeadline,
                          now: record.admissionCreatedAt
                      ) == .admissible,
                      request.workflowVersion == ExtensionBridge.workflowVersion else {
                    return false
                }
            }
            if let responseData = record.state.responseData,
               responseJSON(responseData, id: record.id) == nil {
                return false
            }
            switch record.state {
            case .completed(let since, _, _):
                return since >= record.createdAt
            case .pending, .claimed, .broadcastPrepared:
                return true
            }
        }
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
        sequence: Int
    ) -> ExtensionBridge.Snapshot {
        let request = record.state.requestData.flatMap(parseRequest)
        let phase: ExtensionBridge.Phase
        switch record.state {
        case .pending:
            phase = .queued
        case .claimed, .broadcastPrepared:
            phase = .approving
        case .completed:
            phase = .responded
        }
        return ExtensionBridge.Snapshot(
            handle: record.handle,
            phase: phase,
            request: request,
            nativeDecisionStaged: record.stagedApproval != nil,
            nativeDeliveryNonce: record.nativeDeliveryNonce,
            nativeDeliveryReceipt: record.nativeDeliveryReceipt,
            nativeExecutionContext: record.nativeExecutionContext,
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
            if case .completed(let since, _, _) = record.state,
               canRetireAdmissionRecord(record, now: now) {
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
            ? ExtensionBridge.maximumStoredRecordBytes +
                NativeApprovalDecision.maximumEncodedBytes + 32 * 1024
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
        if response.json[ExtensionBridge.approvalCommittedKey] as? Bool == true {
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
              response["id"] as? Int == id else { return nil }
        return response
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

    private func nativeExecutionFenceStatusLocked(
        handle: ExtensionBridge.Handle
    ) -> OperationLockStatus {
        operationLockStatusLocked(at: nativeExecutionFenceURL(handle))
    }

    private func nativeExecutionFenceIsHeldLocked(
        handle: ExtensionBridge.Handle,
        token: UUID
    ) -> Bool {
        guard nativeExecutionFenceStatusLocked(handle: handle) == .held,
              case .regular = regularFileStatusLocked(
                  at: nativeExecutionFenceOwnerURL(handle)
              ), let data = try? Data(
                  contentsOf: nativeExecutionFenceOwnerURL(handle)
              ), data.count == 36,
              String(data: data, encoding: .utf8) ==
                token.uuidString.lowercased() else { return false }
        return true
    }

    private func executionAuthorityAuthorizesLocked(
        record: Record,
        authority: ExtensionBridge.ExecutionAuthority,
        now: Date
    ) -> Bool {
        switch authority {
        case .ordinary:
            return record.nativeExecutionContext == nil
        case .mobileSigning(let deadline):
            return record.nativeExecutionContext == nil && now < deadline
        case .native(let expected):
            return record.nativeExecutionContext == expected &&
                now >= expected.observedAt &&
                now < expected.executionDeadline &&
                nativeExecutionFenceIsHeldLocked(
                    handle: record.handle,
                    token: expected.fenceToken
                )
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

    private func removeNativeExecutionFenceLocked(
        handle: ExtensionBridge.Handle
    ) {
        guard nativeExecutionFenceStatusLocked(handle: handle) == .unlocked else {
            return
        }
        removeOperationLockLocked(at: nativeExecutionFenceURL(handle))
        let ownerURL = nativeExecutionFenceOwnerURL(handle)
        guard case .regular = regularFileStatusLocked(at: ownerURL) else {
            return
        }
        try? removeItem(ownerURL)
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

    private func writeProfileLocked(_ profile: ProfileState) -> Bool {
        guard prepareDirectoriesLocked() else { return false }
        let url = profileURL(profile.profileIdentifier)
        switch regularFileStatusLocked(at: url) {
        case .missing, .regular:
            break
        case .unsafe, .unavailable:
            return false
        }
        guard let data = try? Self.encode(profile),
              data.count <= Self.maximumProfileBytes else { return false }
        do {
            try atomicWrite(data, url)
            return true
        } catch {
            return false
        }
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    private func removeProfileFileLocked(at url: URL) -> Bool {
        switch regularFileStatusLocked(at: url) {
        case .missing:
            return true
        case .regular:
            break
        case .unsafe, .unavailable:
            return false
        }
        do {
            try removeItem(url)
            return true
        } catch {
            return false
        }
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

    private func emptyProfile(_ profileIdentifier: UUID?) -> ProfileState {
        ProfileState(
            schemaVersion: Self.profileSchemaVersion,
            workflowVersion: ExtensionBridge.workflowVersion,
            profileIdentifier: profileIdentifier,
            records: []
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
            try fileManager.createDirectory(
                at: rootURL.appendingPathComponent(
                    Self.nativeExecutionFenceDirectoryName,
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
            let fenceAttributes = try fileManager.attributesOfItem(
                atPath: nativeExecutionFenceDirectoryURL.path
            )
            return profileAttributes[.type] as? FileAttributeType == .typeDirectory &&
                lockAttributes[.type] as? FileAttributeType == .typeDirectory &&
                fenceAttributes[.type] as? FileAttributeType == .typeDirectory
        } catch {
            return false
        }
    }

    private func withLock<T>(or fallback: T, _ body: () -> T) -> T {
        guard let rootURL, let storeLock else { return fallback }
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
            return fallback
        }
        defer { storeLock.release() }
        return body()
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

    private func nativeExecutionFenceURL(
        _ handle: ExtensionBridge.Handle
    ) -> URL {
        let profile = handle.profileIdentifier?.uuidString.lowercased() ??
            "default"
        return nativeExecutionFenceDirectoryURL
            .appendingPathComponent("\(profile)-\(handle.token.rawValue)")
            .appendingPathExtension("lock")
    }

    private func nativeExecutionFenceOwnerURL(
        _ handle: ExtensionBridge.Handle
    ) -> URL {
        nativeExecutionFenceURL(handle).appendingPathExtension("owner")
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

    private var nativeExecutionFenceDirectoryURL: URL {
        rootURL!.appendingPathComponent(
            Self.nativeExecutionFenceDirectoryName,
            isDirectory: true
        )
    }

    private var profileSweepCursorURL: URL {
        profileDirectoryURL.appendingPathComponent(Self.profileSweepCursorName)
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
