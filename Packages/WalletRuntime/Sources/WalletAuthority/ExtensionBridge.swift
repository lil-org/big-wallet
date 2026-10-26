import WalletDomain
import WalletStorageSupport
// ∅ 2026 lil org

import CryptoKit
import Foundation
import Synchronization

enum WalletAuthorityRemoval: Sendable {
    case wallet(id: String)
    case accounts(Set<WalletAccountDescriptor>)

    func matches(_ account: WalletAccountDescriptor) -> Bool {
        switch self {
        case .wallet(let id): return account.walletID == id
        case .accounts(let accounts): return accounts.contains(account)
        }
    }
}

struct PreparedWalletSourceMutation<Payload> {
    let payload: Payload
    let authorityRemovals: [WalletAuthorityRemoval]
}

protocol WalletSourceMutating: Sendable {
    func perform<Payload, Result>(
        preparing: () throws -> PreparedWalletSourceMutation<Payload>,
        beforeCommit: () throws -> Void,
        commit: (Payload) throws -> Result
    ) throws -> Result
}

public actor ExtensionBridge {
    
    public struct Snapshot: Sendable {
        public enum State: Sendable {
            case queued(request: SafariRequest, approval: QueuedApproval)
            case approving(request: SafariRequest, nativeApproval: NativeApproval?)
            case responded
        }

        public enum QueuedApproval: Sendable {
            case unowned
            case delivered(NativeDeliveryReceipt)
        }

        public struct NativeApproval: Sendable {
            public let receipt: NativeDeliveryReceipt
            public let approvedAt: Date
            public let executionContext: NativeExecutionContext?
        }

        public let handle: RequestHandle
        public let state: State
        public let nativeDeliveryNonce: NativeDeliveryNonce
        public let host: String
        public let configurationKey: String
        public let revisions: ProviderRevisions
        public let createdAt: Date
        public let enqueueAttempt: String
        public let sequence: Int
        let requestBinding: RequestBinding?

        init(
            handle: RequestHandle,
            state: State,
            nativeDeliveryNonce: NativeDeliveryNonce,
            host: String,
            configurationKey: String,
            revisions: ProviderRevisions,
            createdAt: Date,
            enqueueAttempt: String,
            sequence: Int,
            requestBinding: RequestBinding? = nil
        ) {
            self.handle = handle
            self.state = state
            self.nativeDeliveryNonce = nativeDeliveryNonce
            self.host = host
            self.configurationKey = configurationKey
            self.revisions = revisions
            self.createdAt = createdAt
            self.enqueueAttempt = enqueueAttempt
            self.sequence = sequence
            self.requestBinding = requestBinding
        }

        public var phase: RequestPhase {
            switch state {
            case .queued: return .queued
            case .approving: return .approving
            case .responded: return .responded
            }
        }

        public var request: SafariRequest? {
            switch state {
            case .queued(let request, _), .approving(let request, _): return request
            case .responded: return nil
            }
        }

        public var nativeApproval: NativeApproval? {
            switch state {
            case .approving(_, let approval): return approval
            case .queued, .responded: return nil
            }
        }

        public var nativeDeliveryReceipt: NativeDeliveryReceipt? {
            if case .queued(_, .delivered(let receipt)) = state { return receipt }
            return nativeApproval?.receipt
        }

        public var nativeExecutionContext: NativeExecutionContext? {
            nativeApproval?.executionContext
        }

        public var isQueuedForNativeApproval: Bool {
            switch state {
            case .queued(_, .delivered): return true
            case .queued, .approving, .responded: return false
            }
        }

        public var hasActiveExecution: Bool {
            switch state {
            case .approving: return true
            case .queued, .responded: return false
            }
        }
    }
    
    public enum AuthorityReadResult: Sendable { case snapshot(RequestAuthoritySnapshot), unavailable }
    public enum AuthorityMutationResult: Sendable { case revoked(RequestAuthoritySnapshot), stale(RequestAuthoritySnapshot), unavailable }

    public enum RecoveryRequestsResult: Sendable { case available([RecoveryRequest]), unavailable }

    enum ExecutionAuthority: Equatable, Sendable {
        case ordinary(deadline: Date)
        case native(approvedAt: Date, context: NativeExecutionContext)

        var executionDeadline: Date {
            switch self {
            case .ordinary(let deadline): return deadline
            case .native(_, let context): return context.executionDeadline
            }
        }

        func isWithinExecutionWindow(at now: Date) -> Bool {
            guard now < executionDeadline else { return false }
            if case .native(_, let context) = self { return now >= context.observedAt }
            return true
        }

        func allowsExecution(at now: Date, isCancelled: Bool) -> Bool {
            !isCancelled && isWithinExecutionWindow(at: now)
        }

        func isWithinClaimLifetime(at now: Date) -> Bool {
            let remaining = executionDeadline.timeIntervalSince(now)
            return remaining > 0 && remaining <= ExtensionBridge.executionLifetime
        }

        func allowsStoredExecution(at now: Date, isCancelled: Bool) -> Bool {
            guard allowsExecution(at: now, isCancelled: isCancelled) else { return false }
            if case .ordinary = self { return isWithinClaimLifetime(at: now) }
            return true
        }

        func signingDeadline(for request: SafariRequest) -> Date {
            min(executionDeadline, nativeTransactionDecisionDeadline(for: request) ?? executionDeadline)
        }

        func isDecisionFresh(for request: SafariRequest, at now: Date) -> Bool {
            guard case .native(let approvedAt, _) = self,
                  let deadline = nativeTransactionDecisionDeadline(for: request) else { return true }
            return now >= approvedAt && now < deadline
        }

        private func nativeTransactionDecisionDeadline(for request: SafariRequest) -> Date? {
            guard case .native(let approvedAt, _) = self else { return nil }
            let transaction: Bool
            switch request.body {
            case .ethereum(let body):
                transaction = body.method == .signTransaction
            case .solana(let body):
                transaction = body.method == .signTransaction || body.method == .signAllTransactions ||
                    body.method == .signAndSendTransaction
            case .unknown:
                transaction = false
            }
            return transaction ? approvedAt.addingTimeInterval(ExtensionBridge.maximumTransactionDecisionAge) : nil
        }
    }

    public struct Ingress: Sendable {
        let request: SafariRequest
        let canonicalData: Data
        let fingerprint: Data
        let authority: RequestAuthorityVersion
        let replayOnly: Bool
    }

    final class OperationLease: Sendable {
        let fileURL: URL
        private let lock: CrossProcessFileLock

        init(fileURL: URL, lock: CrossProcessFileLock) {
            self.fileURL = fileURL
            self.lock = lock
        }

        func release() {
            lock.release()
        }
        deinit { release() }
    }

    public enum AdmissionKind: Equatable, Sendable {
        case new, replay, coalesced
    }

    public enum EnqueueResult: Sendable {
        case accepted(
            handle: RequestHandle,
            approvalRequired: Bool,
            authority: RequestAuthoritySnapshot,
            admissionKind: AdmissionKind,
            nativeDeliveryNonce: NativeDeliveryNonce
        )
        case unauthorized(RequestAuthoritySnapshot)
        case expired, rejected, manualSwitchCapacityReached, unavailable
    }

    public enum AdmissionDeadlineDisposition: Equatable, Sendable {
        case admissible, expired, invalid
    }

    public enum DappIngressResult: Sendable { case accepted(Ingress), payloadTooLarge, invalid }
    public enum SnapshotResult: Sendable { case found(Snapshot), missing, unavailable }
    public enum SnapshotsResult: Sendable { case available([RequestHandle: Snapshot]), unavailable }

    enum ApprovalClaimResult: Equatable, Sendable {
        case claimed(ApprovalClaim), executing, responded, missing, unavailable
    }

    enum NativeExecutionClaimResult: Equatable, Sendable {
        case claimed(ApprovalClaim)
        case ownershipLost, executing, responded, missing, unavailable, reviewRequired
    }

    public enum StoreMutationResult: Equatable, Sendable {
        case persisted, ownershipLost, retryablePersistenceFailure
    }

    public enum NativeInterruptionResult: Equatable, Sendable {
        case interrupted, responseReady, ownershipLost, retryablePersistenceFailure
    }

    enum AuthorizeExecutionResult: Equatable, Sendable {
        case authorized(ApprovedExecutionPermit), ownershipLost, retryablePersistenceFailure
    }

    enum BroadcastPreparationResult: Equatable, Sendable {
        case prepared(BroadcastDispatchPermit), ownershipLost, retryablePersistenceFailure
    }

    public enum ResponseReadResult: Sendable { case response(WireProtocol.JSONObject), pending, missing, unavailable }
    public enum ResponseStatusResult: Equatable, Sendable { case pending, ready, missing, unavailable }

    public static let workflowVersion = WireProtocol.workflowVersion
    public static let maximumPayloadBytes = WireProtocol.maximumPayloadBytes
    public static let maximumRequestsPerHost = WireProtocol.maximumRequestsPerHost
    public static let maximumRequests = WireProtocol.maximumRequests
    public static let maximumRetainedRequests = WireProtocol.maximumRetainedRequests
    public static let maximumRetainedRequestsPerOrigin = 12
    public static let maximumGlobalRetainedRequests = maximumRetainedRequests
    public static let maximumManualSwitchResponseBytes = maximumPayloadBytes * 2
    public static let maximumStoredRecordBytes = maximumPayloadBytes * 2
    public static let maximumRetainedBytes = maximumRetainedRequests * maximumStoredRecordBytes
    public static let maximumRetainedBytesPerOrigin =
        maximumRetainedRequestsPerOrigin * maximumStoredRecordBytes
    public static let executionLifetime: TimeInterval = 150
    public static let maximumTransactionDecisionAge: TimeInterval = 30
    public static let requestTTL: TimeInterval = TimeInterval(WireProtocol.requestTTLMilliseconds) / 1_000
    public static let admissionDeadlineFutureSkew: TimeInterval = 60
    public static let responseExpiry: TimeInterval = TimeInterval(WireProtocol.responseExpiryMilliseconds) / 1_000

    private let store: ExtensionRequestFileStore
    private let hooks: AuthorityExecutionHooks
    init(store: ExtensionRequestFileStore, hooks: AuthorityExecutionHooks = .none) {
        self.store = store
        self.hooks = hooks
    }

    public static func payloadData(
        _ payload: [String: Any],
        options: JSONSerialization.WritingOptions = []
    ) -> Data? {
        guard JSONSerialization.isValidJSONObject(payload) else { return nil }
        return try? JSONSerialization.data(withJSONObject: payload, options: options)
    }

    public static func isPayloadWithinLimit(_ payload: [String: Any]) -> Bool {
        payloadData(payload).map { $0.count <= maximumPayloadBytes } ?? false
    }

    static func dappIngressResult(
        request: SafariRequest,
        rawObject: [String: Any]
    ) -> DappIngressResult {
        guard let wire = WireProtocol.object(.dappRequest, value: rawObject) else { return .invalid }
        return dappIngressResult(request: request, wire: wire)
    }

    static func dappIngressResult(
        request: SafariRequest,
        wire: WireProtocol.ValidatedObject
    ) -> DappIngressResult {
        guard wire.contract == .dappRequest else { return .invalid }
        var rawObject = wire.json
        let replayOnly = rawObject.removeValue(forKey: "replayOnly") as? Bool ?? false
        guard request.workflowVersion == workflowVersion,
              isValidIdentity(
                  host: request.host,
                  configurationKey: request.configurationKey
              ),
              rawObject["configurationKey"] as? String == request.configurationKey,
              isValidEnqueueAttempt(request.enqueueAttempt),
              let authorityJSON = rawObject["authority"] as? [String: Any],
              let authority = RequestAuthorityVersion(validatedJSON: authorityJSON),
              let canonicalData = payloadData(rawObject, options: [.sortedKeys]) else {
            return .invalid
        }
        guard canonicalData.count <= maximumPayloadBytes else { return .payloadTooLarge }
        guard let fingerprint = correlationFingerprint(rawObject) else {
            return .invalid
        }
        return .accepted(Ingress(
            request: request,
            canonicalData: canonicalData,
            fingerprint: fingerprint,
            authority: authority,
            replayOnly: replayOnly
        ))
    }

    static func correlationFingerprint(_ rawObject: [String: Any]) -> Data? {
        var correlationObject = rawObject
        correlationObject.removeValue(forKey: "authority")

        if correlationObject["provider"] as? String == InpageProvider.unknown.rawValue,
           correlationObject["name"] as? String == "switchAccount" {
            correlationObject["body"] = ["latestConfigurations": []]
        }
        guard let data = payloadData(correlationObject, options: [.sortedKeys]) else {
            return nil
        }
        return Data(SHA256.hash(data: data))
    }

    public static func isValidIdentity(
        host: String,
        configurationKey: String
    ) -> Bool {
        guard !host.isEmpty, !configurationKey.isEmpty,
              let url = URL(string: configurationKey),
              url.fragment == nil else { return false }
        if url.scheme == "file" {
            return host == configurationKey
        }
        guard url.scheme == "http" || url.scheme == "https",
              url.user == nil, url.password == nil,
              url.query == nil, url.path.isEmpty,
              let separator = configurationKey.range(of: "://") else {
            return false
        }
        return configurationKey[separator.upperBound...] == host
    }

    public static func isInternalPayloadAllowed(
        command: InternalSafariRequest.Command,
        byteCount: Int
    ) -> Bool {
        guard byteCount >= 0 else { return false }
        if case .page(.rpc) = command { return byteCount <= WireProtocol.rpcMaximumRequestBytes }
        return byteCount <= maximumPayloadBytes
    }

    public static func isValidEnqueueAttempt(_ value: String) -> Bool {
        WireProtocol.validate(.privateToken, value: value)
    }

    public static func admissionDeadlineDisposition(
        _ deadline: Date,
        now: Date
    ) -> AdmissionDeadlineDisposition {
        guard deadline > now else { return .expired }
        guard deadline <= now.addingTimeInterval(
            requestTTL + admissionDeadlineFutureSkew
        ) else { return .invalid }
        return .admissible
    }

    public static func lowercaseUUID(_ rawValue: String) -> UUID? {
        guard WireProtocol.validate(.requestToken, value: rawValue),
              let value = UUID(uuidString: rawValue) else { return nil }
        return value
    }

    public func enqueue(
        ingress: Ingress,
        profileIdentifier: UUID?,
        privateBrowsing: Bool = false
    ) -> EnqueueResult {
        guard !privateBrowsing else { return .rejected }
        let result = store.enqueue(ingress: ingress, profileIdentifier: profileIdentifier)
        if case .accepted(let handle, _, _, _, _) = result {
            hooks.event(.init(.requestAdmitted, handle: handle))
        }
        return result
    }

    public func configurationSnapshot(configurationKey: String, profileIdentifier: UUID?) -> AuthorityReadResult {
        store.configurationSnapshot(configurationKey: configurationKey, profileIdentifier: profileIdentifier)
    }

    public func revoke(configurationKey: String, provider: InpageProvider, attempt: String,
                expected: RequestAuthorityVersion, profileIdentifier: UUID?) -> AuthorityMutationResult {
        let result = store.revoke(configurationKey: configurationKey, provider: provider, attempt: attempt,
                                  expected: expected, profileIdentifier: profileIdentifier)
        return result
    }

    public func listRecoveryRequests(profileIdentifier: UUID?) -> RecoveryRequestsResult {
        store.listRecoveryRequests(profileIdentifier: profileIdentifier)
    }

    public func authorityIsCurrent(handle: RequestHandle) -> Bool {
        store.authorityIsCurrent(handle: handle)
    }

    public func list(profileIdentifier: UUID?) -> SnapshotsResult {
        store.list(profileIdentifier: profileIdentifier)
    }

    public func performMaintenance() {
        store.performMaintenance()
    }

    public func performMaintenance(profileIdentifier: UUID?) {
        store.performMaintenance(profileIdentifier: profileIdentifier)
    }

    public func responseStatus(
        handle: RequestHandle,
        configurationKey: String
    ) -> ResponseStatusResult {
        store.responseStatus(
            handle: handle, configurationKey: configurationKey
        )
    }

    public func load(handle: RequestHandle) -> SnapshotResult { store.load(handle: handle) }
    func claim(handle: RequestHandle) -> ApprovalClaimResult { store.claim(handle: handle) }
    func claimNativeExecution(consent: ReviewConsent) -> NativeExecutionClaimResult {
        store.claimNativeExecution(consent: consent)
    }

    public func recordNativeDeliveryReceipt(
        handle: RequestHandle,
        nativeDeliveryNonce: NativeDeliveryNonce,
        owner: NativeDeliveryOwner
    ) -> StoreMutationResult {
        store.recordNativeDeliveryReceipt(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            owner: owner
        )
    }

    public func clearNativeDeliveryReceipt(
        handle: RequestHandle,
        nativeDeliveryNonce: NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID
    ) -> StoreMutationResult {
        store.clearNativeDeliveryReceipt(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtimeInstanceIdentifier
        )
    }

    public func interruptNativeApproval(
        handle: RequestHandle,
        nativeDeliveryNonce: NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID
    ) -> NativeInterruptionResult {
        store.interruptNativeApproval(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtimeInstanceIdentifier
        )
    }

    func completeNativeImmediate(
        handle: RequestHandle,
        nativeDeliveryNonce: NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        resolution: ImmediateResolution
    ) -> StoreMutationResult {
        store.completeNativeImmediate(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtimeInstanceIdentifier,
            resolution: resolution
        )
    }

    public func rejectNativeDelivery(
        handle: RequestHandle,
        nativeDeliveryNonce: NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID
    ) -> StoreMutationResult {
        store.rejectNativeDelivery(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtimeInstanceIdentifier
        )
    }

    func abandon(claim: ApprovalClaim) -> StoreMutationResult { store.abandon(claim: claim) }

    func returnToReview(claim: ApprovalClaim, consent: ReviewConsent) -> StoreMutationResult {
        store.returnToReview(claim: claim, consent: consent)
    }

    func completeImmediate(handle: RequestHandle, resolution: ImmediateResolution) -> StoreMutationResult {
        store.completeImmediate(handle: handle, resolution: resolution)
    }

    public func reject(handle: RequestHandle) -> StoreMutationResult {
        store.reject(handle: handle)
    }

    func authorize(
        claim: ApprovalClaim,
        approval: ResolvedDappApproval
    ) -> AuthorizeExecutionResult {
        store.authorize(claim: claim, approval: approval)
    }

    func complete(claim: ApprovalClaim, resolution: ImmediateResolution) -> StoreMutationResult {
        store.complete(claim: claim, resolution: resolution)
    }

    func prepareBroadcast(
        permit: ApprovedExecutionPermit,
        broadcast: PreparedBroadcast
    ) -> BroadcastPreparationResult {
        store.prepareBroadcast(permit: permit, broadcast: broadcast)
    }

    func complete(permit: ApprovedExecutionPermit, result: ApprovedCompletion) -> StoreMutationResult {
        store.complete(permit: permit, result: result)
    }

    func abandon(permit: ApprovedExecutionPermit) -> StoreMutationResult {
        store.abandon(permit: permit)
    }

    public func prepareResponseDelivery(
        id: Int,
        configurationKey: String,
        requestToken: String,
        profileIdentifier: UUID?
    ) -> ResponseReadResult {
        guard let handle = RequestHandle(
            id: id,
            requestToken: requestToken,
            profileIdentifier: profileIdentifier
        ) else { return .missing }
        return store.prepareResponseDelivery(handle: handle, configurationKey: configurationKey)
    }

    public func acknowledgeResponse(
        handle: RequestHandle,
        configurationKey: String
    ) -> StoreMutationResult {
        store.acknowledgeResponse(
            handle: handle,
            configurationKey: configurationKey
        )
    }
    
}

protocol PopupRequestStore: AnyObject, Sendable {
    func authorityIsCurrent(handle: RequestHandle) async -> Bool
    func list(profileIdentifier: UUID?) async -> ExtensionBridge.SnapshotsResult
    func load(handle: RequestHandle) async -> ExtensionBridge.SnapshotResult
    func claim(handle: RequestHandle) async -> ExtensionBridge.ApprovalClaimResult
    func completeImmediate(handle: RequestHandle, resolution: ImmediateResolution) async -> ExtensionBridge.StoreMutationResult
    func reject(handle: RequestHandle) async -> ExtensionBridge.StoreMutationResult
    func abandon(claim: ExtensionBridge.ApprovalClaim) async -> ExtensionBridge.StoreMutationResult
    func returnToReview(
        claim: ExtensionBridge.ApprovalClaim,
        consent: ReviewConsent
    ) async -> ExtensionBridge.StoreMutationResult
    func authorize(
        claim: ExtensionBridge.ApprovalClaim,
        approval: ResolvedDappApproval
    ) async -> ExtensionBridge.AuthorizeExecutionResult
    func complete(
        claim: ExtensionBridge.ApprovalClaim,
        resolution: ImmediateResolution
    ) async -> ExtensionBridge.StoreMutationResult
    func prepareBroadcast(
        permit: ExtensionBridge.ApprovedExecutionPermit,
        broadcast: PreparedBroadcast
    ) async -> ExtensionBridge.BroadcastPreparationResult
    func complete(
        permit: ExtensionBridge.ApprovedExecutionPermit,
        result: ApprovedCompletion
    ) async -> ExtensionBridge.StoreMutationResult
    func abandon(permit: ExtensionBridge.ApprovedExecutionPermit) async -> ExtensionBridge.StoreMutationResult
}

extension ExtensionBridge: PopupRequestStore {}

protocol NativeApprovalStore: PopupRequestStore {
    func claimNativeExecution(consent: ReviewConsent) async -> ExtensionBridge.NativeExecutionClaimResult
}

extension ExtensionBridge: NativeApprovalStore {}

