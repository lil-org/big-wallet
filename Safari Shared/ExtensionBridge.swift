// ∅ 2026 lil org

import CryptoKit
import CoreFoundation
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

enum NativeApprovalTiming: Sendable {
    static let recoveryTimeout: TimeInterval = 10
    static let recoveryRetryInterval: TimeInterval = 1
    static let recoveryRetryNanoseconds = UInt64(recoveryRetryInterval * 1_000_000_000)
    static let observationInitialDelayNanoseconds: UInt64 = 1_000_000_000
    static let observationMaximumDelayNanoseconds: UInt64 = 5_000_000_000
    static let launchTimeoutNanoseconds: UInt64 = 5_000_000_000
    static let launchPollIntervalNanoseconds: UInt64 = 50_000_000
    static let runtimeIdentityGracePeriodNanoseconds: UInt64 = 1_000_000_000
    static let receiptWaitTimeoutNanoseconds: UInt64 = 250_000_000
    static let responseTimeoutNanoseconds: UInt64 = 170_000_000_000
    static let responsePollIntervalNanoseconds: UInt64 = 250_000_000
    static let deliveryCheckIntervalNanoseconds: UInt64 = 1_000_000_000
}

actor ExtensionBridge {
    enum PrivateBrowsingContextExtraction: Equatable, Sendable {
        case missing, value(Bool), malformed
    }
    
    struct RequestToken: Hashable, Codable, Sendable {
        let value: UUID

        init(value: UUID) { self.value = value }

        init?(rawValue: String) {
            guard let value = ExtensionBridge.lowercaseUUID(rawValue) else { return nil }
            self.value = value
        }

        var rawValue: String { value.uuidString.lowercased() }
    }

    struct NativeDeliveryNonce: Hashable, Codable, Sendable {
        let value: UUID

        init(value: UUID) { self.value = value }

        init?(rawValue: String) {
            guard let value = ExtensionBridge.lowercaseUUID(rawValue) else {
                return nil
            }
            self.value = value
        }

        var rawValue: String { value.uuidString.lowercased() }
    }

    struct NativeDeliveryOwner: Codable, Equatable, Sendable {
        let runtimeInstanceIdentifier: UUID
        let processIdentifier: Int32
        let processStartDate: Date
        let bundlePath: String
        let marketingVersion: String
        let buildVersion: String

        init?(
            runtimeInstanceIdentifier: UUID,
            processIdentifier: Int32,
            processStartDate: Date,
            bundleURL: URL,
            marketingVersion: String,
            buildVersion: String
        ) {
            self.runtimeInstanceIdentifier = runtimeInstanceIdentifier
            self.processIdentifier = processIdentifier
            self.processStartDate = processStartDate
            bundlePath = bundleURL.standardizedFileURL.path
            self.marketingVersion = marketingVersion
            self.buildVersion = buildVersion
            guard isValid else { return nil }
        }

        var bundleURL: URL {
            URL(fileURLWithPath: bundlePath).standardizedFileURL
        }

        var isValid: Bool {
            processIdentifier > 0 &&
                processStartDate.timeIntervalSince1970.isFinite &&
                processStartDate.timeIntervalSince1970 > 0 &&
                !bundlePath.isEmpty && bundlePath.count <= 4_096 &&
                bundleURL.path == bundlePath &&
                bundleURL.pathExtension == "app" &&
                !marketingVersion.isEmpty && marketingVersion.count <= 128 &&
                !buildVersion.isEmpty && buildVersion.count <= 128
        }
    }

    struct NativeDeliveryReceipt: Codable, Equatable, Sendable {
        let nativeDeliveryNonce: NativeDeliveryNonce
        let owner: NativeDeliveryOwner
    
        init(
            nativeDeliveryNonce: NativeDeliveryNonce,
            owner: NativeDeliveryOwner
        ) {
            self.nativeDeliveryNonce = nativeDeliveryNonce
            self.owner = owner
        }

        func matches(
            nativeDeliveryNonce: NativeDeliveryNonce,
            runtimeInstanceIdentifier: UUID
        ) -> Bool {
            self.nativeDeliveryNonce == nativeDeliveryNonce &&
                owner.runtimeInstanceIdentifier == runtimeInstanceIdentifier
        }
    }

    struct Handle: Hashable, Sendable {
        let id: Int
        let token: RequestToken
        let profileIdentifier: UUID?

        init(id: Int, token: RequestToken, profileIdentifier: UUID?) {
            self.id = id
            self.token = token
            self.profileIdentifier = profileIdentifier
        }

        init?(id: Int, requestToken: String, profileIdentifier: UUID?) {
            guard let token = RequestToken(rawValue: requestToken) else { return nil }
            self.init(id: id, token: token, profileIdentifier: profileIdentifier)
        }

        var requestToken: String { token.rawValue }
    }

    enum Phase: String, Codable, Sendable { case queued, approving, responded }

    enum ManualSwitchRequestState: String, Sendable {
        case pending, approved, completed
    }

    struct ManualSwitchRequest: Equatable, Sendable {
        let handle: Handle
        let host: String
        let configurationKey: String
        let revisions: ProviderRevisions
        let state: ManualSwitchRequestState

        var json: [String: Any] {
            [
                "id": handle.id,
                "host": host,
                "configurationKey": configurationKey,
                "requestToken": handle.requestToken,
                "revisions": revisions.json,
                "state": state.rawValue,
            ]
        }
    }

    struct Snapshot: Sendable {
        enum State: Sendable {
            case queued(request: SafariRequest, approval: QueuedApproval)
            case approving(request: SafariRequest, nativeApproval: NativeApproval?)
            case responded
        }

        enum QueuedApproval: Sendable {
            case unowned
            case delivered(NativeDeliveryReceipt)
        }

        struct NativeApproval: Sendable {
            let receipt: NativeDeliveryReceipt
            let approvedAt: Date
            let executionContext: NativeExecutionContext?
        }

        let handle: Handle
        let state: State
        let nativeDeliveryNonce: NativeDeliveryNonce
        let host: String
        let configurationKey: String
        let revisions: ProviderRevisions
        let createdAt: Date
        let enqueueAttempt: String
        let sequence: Int
        let requestBinding: RequestBinding?

        init(
            handle: Handle,
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

        var phase: Phase {
            switch state {
            case .queued: return .queued
            case .approving: return .approving
            case .responded: return .responded
            }
        }

        var request: SafariRequest? {
            switch state {
            case .queued(let request, _), .approving(let request, _): return request
            case .responded: return nil
            }
        }

        var nativeApproval: NativeApproval? {
            switch state {
            case .approving(_, let approval): return approval
            case .queued, .responded: return nil
            }
        }

        var nativeDeliveryReceipt: NativeDeliveryReceipt? {
            if case .queued(_, .delivered(let receipt)) = state { return receipt }
            return nativeApproval?.receipt
        }

        var nativeExecutionContext: NativeExecutionContext? {
            nativeApproval?.executionContext
        }

        var isQueuedForNativeApproval: Bool {
            switch state {
            case .queued(_, .delivered): return true
            case .queued, .approving, .responded: return false
            }
        }

        var hasActiveExecution: Bool {
            switch state {
            case .approving: return true
            case .queued, .responded: return false
            }
        }
    }
    
    struct ProviderRevisions: Codable, Equatable, Sendable {
        let ethereum: Int
        let solana: Int

        init?(rawValue: Any?) {
            guard let rawValue,
                  let value = WireProtocol.decode(.revisions, value: rawValue) as? [String: Any] else { return nil }
            self.init(validatedJSON: value)
        }

        fileprivate init?(validatedJSON: [String: Any]) {
            guard let ethereum = validatedJSON["ethereum"] as? Int,
                  let solana = validatedJSON["solana"] as? Int else { return nil }
            self.ethereum = ethereum
            self.solana = solana
        }

        init(from decoder: Decoder) throws {
            let wire = try WireProtocol.object(.revisions, from: decoder)
            guard let value = Self(validatedJSON: wire.json) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "invalid provider revisions"
                ))
            }
            self = value
        }

        var json: [String: Any] { ["ethereum": ethereum, "solana": solana] }
    }

    struct AuthorityVersion: Codable, Equatable, Sendable {
        let context: String
        let revisions: ProviderRevisions

        init(context: String, revisions: ProviderRevisions) {
            self.context = context
            self.revisions = revisions
        }

        init?(rawValue: Any?) {
            guard let rawValue,
                  let value = WireProtocol.decode(.authorityVersion, value: rawValue) as? [String: Any] else { return nil }
            self.init(validatedJSON: value)
        }

        init?(validatedJSON: [String: Any]) {
            guard let context = validatedJSON["context"] as? String,
                  let values = validatedJSON["revisions"] as? [String: Any],
                  let revisions = ProviderRevisions(validatedJSON: values) else { return nil }
            self.init(context: context, revisions: revisions)
        }

        init(from decoder: Decoder) throws {
            let wire = try WireProtocol.object(.authorityVersion, from: decoder)
            guard let version = Self(validatedJSON: wire.json) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "invalid authority version"
                ))
            }
            self = version
        }

        var json: [String: Any] { ["context": context, "revisions": revisions.json] }
    }

    struct AuthoritySnapshot: Sendable {
        let version: AuthorityVersion
        let ethereumAccount: WalletAccountDescriptor?
        let ethereumChainId: String
        let solanaAccount: WalletAccountDescriptor?

        var json: [String: Any] {
            [
                "context": version.context,
                "revisions": version.revisions.json,
                "ethereum": ["address": ethereumAccount?.normalizedAddress ?? "", "chainId": ethereumChainId],
                "solana": solanaAccount.map { ["publicKey": $0.normalizedAddress] as Any } ?? NSNull(),
            ]
        }
    }

    enum AuthorityReadResult: Sendable { case snapshot(AuthoritySnapshot), unavailable }
    enum AuthorityMutationResult: Sendable { case revoked(AuthoritySnapshot), stale(AuthoritySnapshot), unavailable }

    struct RecoveryRequest: Sendable {
        let handle: Handle
        let configurationKey: String
        let manual: Bool
        let state: ManualSwitchRequestState

        var json: [String: Any] {
            ["id": handle.id, "requestToken": handle.requestToken,
             "configurationKey": configurationKey, "manual": manual, "state": state.rawValue]
        }
    }

    enum RecoveryRequestsResult: Sendable { case available([RecoveryRequest]), unavailable }

    struct NativeExecutionContext: Codable, Equatable, Sendable {
        let revisions: ProviderRevisions
        let observedAt: Date
        let executionDeadline: Date
    }
    
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
            if case .native = self, isCancelled { return false }
            return isWithinExecutionWindow(at: now)
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

    struct Ingress: Sendable {
        let request: SafariRequest
        let canonicalData: Data
        let fingerprint: Data
        let authority: AuthorityVersion
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

    enum AdmissionKind: Equatable, Sendable {
        case new, replay, coalesced
    }

    enum EnqueueResult: Sendable {
        case accepted(
            handle: Handle,
            approvalRequired: Bool,
            authority: AuthoritySnapshot,
            admissionKind: AdmissionKind,
            nativeDeliveryNonce: NativeDeliveryNonce
        )
        case unauthorized(AuthoritySnapshot)
        case expired, rejected, manualSwitchCapacityReached, unavailable
    }

    enum AdmissionDeadlineDisposition: Equatable, Sendable {
        case admissible, expired, invalid
    }

    enum DappIngressResult: Sendable { case accepted(Ingress), payloadTooLarge, invalid }
    enum SnapshotResult: Sendable { case found(Snapshot), missing, unavailable }
    enum SnapshotsResult: Sendable { case available([Handle: Snapshot]), unavailable }

    enum ApprovalClaimResult: Equatable, Sendable {
        case claimed(ApprovalClaim), executing, responded, missing, unavailable
    }

    enum NativeExecutionClaimResult: Equatable, Sendable {
        case claimed(ApprovalClaim)
        case ownershipLost, executing, responded, missing, unavailable, reviewRequired
    }

    enum StoreMutationResult: Equatable, Sendable {
        case persisted, ownershipLost, retryablePersistenceFailure
    }

    enum NativeInterruptionResult: Equatable, Sendable {
        case interrupted, responseReady, ownershipLost, retryablePersistenceFailure
    }

    enum AuthorizeExecutionResult: Equatable, Sendable {
        case authorized(ApprovedExecutionPermit), ownershipLost, retryablePersistenceFailure
    }

    enum BroadcastPreparationResult: Equatable, Sendable {
        case prepared(BroadcastDispatchPermit), ownershipLost, retryablePersistenceFailure
    }

    enum ResponseReadResult: Sendable { case response(WireProtocol.JSONObject), pending, missing, unavailable }
    enum ResponseStatusResult: Equatable, Sendable { case pending, ready, missing, unavailable }

    static let workflowVersion = WireProtocol.workflowVersion
    static let maximumPayloadBytes = WireProtocol.maximumPayloadBytes
    static let maximumRequestsPerHost = WireProtocol.maximumRequestsPerHost
    static let maximumRequests = WireProtocol.maximumRequests
    static let maximumRetainedRequests = WireProtocol.maximumRetainedRequests
    static let maximumRetainedRequestsPerOrigin = 12
    static let maximumGlobalRetainedRequests = maximumRetainedRequests
    static let maximumManualSwitchResponseBytes = maximumPayloadBytes * 2
    static let maximumStoredRecordBytes = maximumPayloadBytes * 2
    static let maximumRetainedBytes = maximumRetainedRequests * maximumStoredRecordBytes
    static let maximumRetainedBytesPerOrigin =
        maximumRetainedRequestsPerOrigin * maximumStoredRecordBytes
    static let executionLifetime: TimeInterval = 150
    static let maximumTransactionDecisionAge: TimeInterval = 30
    static let requestTTL: TimeInterval = TimeInterval(WireProtocol.requestTTLMilliseconds) / 1_000
    static let admissionDeadlineFutureSkew: TimeInterval = 60
    static let responseExpiry: TimeInterval = TimeInterval(WireProtocol.responseExpiryMilliseconds) / 1_000
    static let privateBrowsingKey = WireProtocol.privateBrowsingKey

    static let shared = ExtensionBridge(store: ExtensionRequestFileStore(
        containerURL: FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedDefaults.suiteName
        )
    ))

    struct WalletSourceMutator: WalletSourceMutating {
        func perform<Payload, Result>(
            preparing: () throws -> PreparedWalletSourceMutation<Payload>,
            beforeCommit: () throws -> Void,
            commit: (Payload) throws -> Result
        ) throws -> Result {
            let store = ExtensionRequestFileStore(containerURL: FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: SharedDefaults.suiteName
            ))
            return try store.perform(
                preparing: preparing,
                beforeCommit: beforeCommit,
                commit: commit
            )
        }
    }

    private let store: ExtensionRequestFileStore
    init(store: ExtensionRequestFileStore) { self.store = store }

    static func payloadData(
        _ payload: [String: Any],
        options: JSONSerialization.WritingOptions = []
    ) -> Data? {
        guard JSONSerialization.isValidJSONObject(payload) else { return nil }
        return try? JSONSerialization.data(withJSONObject: payload, options: options)
    }

    static func isPayloadWithinLimit(_ payload: [String: Any]) -> Bool {
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
              let authority = AuthorityVersion(rawValue: rawObject["authority"]),
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

    static func isValidIdentity(
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

    static func isInternalPayloadAllowed(
        command: InternalSafariRequest.Command,
        byteCount: Int
    ) -> Bool {
        guard byteCount >= 0 else { return false }
        if case .page(.rpc) = command { return true }
        return byteCount <= maximumPayloadBytes
    }

    static func isValidEnqueueAttempt(_ value: String) -> Bool {
        WireProtocol.validate(.privateToken, value: value)
    }

    static func admissionDeadlineDisposition(
        _ deadline: Date,
        now: Date
    ) -> AdmissionDeadlineDisposition {
        guard deadline > now else { return .expired }
        guard deadline <= now.addingTimeInterval(
            requestTTL + admissionDeadlineFutureSkew
        ) else { return .invalid }
        return .admissible
    }

    static func lowercaseUUID(_ rawValue: String) -> UUID? {
        guard WireProtocol.validate(.requestToken, value: rawValue),
              let value = UUID(uuidString: rawValue) else { return nil }
        return value
    }

    static func takePrivateBrowsing(
        from message: inout [String: Any]
    ) -> PrivateBrowsingContextExtraction {
        guard let value = message.removeValue(forKey: privateBrowsingKey) else {
            return .missing
        }
        guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
              let privateBrowsing = value as? Bool else { return .malformed }
        return .value(privateBrowsing)
    }

    func enqueue(
        ingress: Ingress,
        profileIdentifier: UUID?,
        privateBrowsing: Bool = false
    ) -> EnqueueResult {
        guard !privateBrowsing else { return .rejected }
        return store.enqueue(ingress: ingress, profileIdentifier: profileIdentifier)
    }

    func configurationSnapshot(configurationKey: String, profileIdentifier: UUID?) -> AuthorityReadResult {
        store.configurationSnapshot(configurationKey: configurationKey, profileIdentifier: profileIdentifier)
    }

    func revoke(configurationKey: String, provider: InpageProvider, attempt: String,
                expected: AuthorityVersion, profileIdentifier: UUID?) -> AuthorityMutationResult {
        store.revoke(configurationKey: configurationKey, provider: provider, attempt: attempt,
                     expected: expected, profileIdentifier: profileIdentifier)
    }

    func listRecoveryRequests(profileIdentifier: UUID?) -> RecoveryRequestsResult {
        store.listRecoveryRequests(profileIdentifier: profileIdentifier)
    }

    func authorityIsCurrent(handle: Handle) -> Bool {
        store.authorityIsCurrent(handle: handle)
    }

    func list(profileIdentifier: UUID?) -> SnapshotsResult {
        store.list(profileIdentifier: profileIdentifier)
    }

    func performMaintenance() {
        store.performMaintenance()
    }

    func performMaintenance(profileIdentifier: UUID?) {
        store.performMaintenance(profileIdentifier: profileIdentifier)
    }

    func responseStatus(
        handle: Handle,
        configurationKey: String
    ) -> ResponseStatusResult {
        store.responseStatus(
            handle: handle, configurationKey: configurationKey
        )
    }

    func load(handle: Handle) -> SnapshotResult { store.load(handle: handle) }
    func claim(handle: Handle) -> ApprovalClaimResult { store.claim(handle: handle) }
    func claimNativeExecution(consent: ReviewConsent) -> NativeExecutionClaimResult {
        store.claimNativeExecution(consent: consent)
    }

    func recordNativeDeliveryReceipt(
        handle: Handle,
        nativeDeliveryNonce: NativeDeliveryNonce,
        owner: NativeDeliveryOwner
    ) -> StoreMutationResult {
        store.recordNativeDeliveryReceipt(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            owner: owner
        )
    }

    func clearNativeDeliveryReceipt(
        handle: Handle,
        nativeDeliveryNonce: NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID
    ) -> StoreMutationResult {
        store.clearNativeDeliveryReceipt(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtimeInstanceIdentifier
        )
    }

    func interruptNativeApproval(
        handle: Handle,
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
        handle: Handle,
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

    func rejectNativeDelivery(
        handle: Handle,
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

    func completeImmediate(handle: Handle, resolution: ImmediateResolution) -> StoreMutationResult {
        store.completeImmediate(handle: handle, resolution: resolution)
    }

    func reject(handle: Handle) -> StoreMutationResult {
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

    func prepareResponseDelivery(
        id: Int,
        configurationKey: String,
        requestToken: String,
        profileIdentifier: UUID?
    ) -> ResponseReadResult {
        guard let handle = Handle(
            id: id,
            requestToken: requestToken,
            profileIdentifier: profileIdentifier
        ) else { return .missing }
        return store.prepareResponseDelivery(handle: handle, configurationKey: configurationKey)
    }

    func acknowledgeResponse(
        handle: Handle,
        configurationKey: String
    ) -> StoreMutationResult {
        store.acknowledgeResponse(
            handle: handle,
            configurationKey: configurationKey
        )
    }
    
}

protocol PopupRequestStore: AnyObject, Sendable {
    func authorityIsCurrent(handle: ExtensionBridge.Handle) async -> Bool
    func list(profileIdentifier: UUID?) async -> ExtensionBridge.SnapshotsResult
    func load(handle: ExtensionBridge.Handle) async -> ExtensionBridge.SnapshotResult
    func claim(handle: ExtensionBridge.Handle) async -> ExtensionBridge.ApprovalClaimResult
    func completeImmediate(handle: ExtensionBridge.Handle, resolution: ImmediateResolution) async -> ExtensionBridge.StoreMutationResult
    func reject(handle: ExtensionBridge.Handle) async -> ExtensionBridge.StoreMutationResult
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

final class ExtensionRequestResponder: Sendable {
    private let context: Mutex<NSExtensionContext?>

    init(context: sending NSExtensionContext) {
        self.context = Mutex(context)
    }

    func cancelRequest(withError error: Error) {
        context.withLock { context in
            guard let current = context else { return }
            context = nil
            current.cancelRequest(withError: error)
        }
    }

    func complete(with response: WireProtocol.ValidatedObject) {
        context.withLock { context in
            guard let current = context else { return }
            context = nil
            let item = NSExtensionItem()
            item.userInfo = ["message": response.json]
            current.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}
