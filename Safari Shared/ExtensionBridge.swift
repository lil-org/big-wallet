// ∅ 2026 lil org

import CryptoKit
import CoreFoundation
import Foundation

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

protocol WalletSourceMutating {
    func perform<Payload, Result>(
        preparing: () throws -> PreparedWalletSourceMutation<Payload>,
        beforeCommit: () throws -> Void,
        commit: (Payload) throws -> Result
    ) throws -> Result
}

enum NativeApprovalTiming {
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
    enum PrivateBrowsingContextExtraction: Equatable {
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

    enum Phase: String, Codable { case queued, approving, responded }

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

    enum ManualSwitchRequestsResult: Equatable, Sendable {
        case available([ManualSwitchRequest])
        case unavailable
    }

    struct Snapshot {
        enum State {
            case queued(request: SafariRequest, approval: QueuedApproval)
            case approving(request: SafariRequest, nativeApproval: NativeApproval?)
            case responded
        }

        enum QueuedApproval {
            case unowned
            case delivered(NativeDeliveryReceipt)
        }

        struct NativeApproval {
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
            guard let value = rawValue as? [String: Any],
                  Set(value.keys) == Set(["ethereum", "solana"]),
                  let ethereumValue = value["ethereum"],
                  CFGetTypeID(ethereumValue as CFTypeRef) != CFBooleanGetTypeID(),
                  let ethereum = ethereumValue as? Int,
                  let solanaValue = value["solana"],
                  CFGetTypeID(solanaValue as CFTypeRef) != CFBooleanGetTypeID(),
                  let solana = solanaValue as? Int,
                  Self.isValid(ethereum), Self.isValid(solana) else { return nil }
            self.ethereum = ethereum
            self.solana = solana
        }

        init(from decoder: Decoder) throws {
            let rawValue = try [String: Int](from: decoder)
            guard let value = Self(rawValue: rawValue) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "invalid provider revisions"
                ))
            }
            self = value
        }

        var json: [String: Any] {
            return ["ethereum": ethereum, "solana": solana]
        }

        private static func isValid(_ value: Int) -> Bool {
            return value >= 0 && value <= 9_007_199_254_740_991
        }
    }
    
    struct AuthorityVersion: Codable, Equatable, Sendable {
        let context: String
        let revisions: ProviderRevisions

        init(context: String, revisions: ProviderRevisions) {
            self.context = context
            self.revisions = revisions
        }

        init?(rawValue: Any?) {
            guard let value = rawValue as? [String: Any],
                  Set(value.keys) == ["context", "revisions"],
                  let context = value["context"] as? String,
                  context.count == 64,
                  context.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let revisions = ProviderRevisions(rawValue: value["revisions"]) else { return nil }
            self.init(context: context, revisions: revisions)
        }

        private struct Field: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Field.self)
            guard Set(values.allKeys.map(\.stringValue)) == ["context", "revisions"] else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid authority fields"))
            }
            let context = try values.decode(String.self, forKey: Field(stringValue: "context")!)
            let revisions = try values.decode(ProviderRevisions.self, forKey: Field(stringValue: "revisions")!)
            guard let version = Self(rawValue: ["context": context, "revisions": revisions.json]) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid authority context"))
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

    enum AuthorityReadResult { case snapshot(AuthoritySnapshot), unavailable }
    enum AuthorityMutationResult { case revoked(AuthoritySnapshot), stale(AuthoritySnapshot), unavailable }

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

    enum RecoveryRequestsResult { case available([RecoveryRequest]), unavailable }

    struct NativeExecutionContext: Codable, Equatable, Sendable {
        let attemptID: UUID
        let revisions: ProviderRevisions
        let observedAt: Date
        let executionDeadline: Date
        let fenceToken: UUID
    }
    
    enum ExecutionAuthority: Equatable, Sendable {
        case ordinary
        case mobileSigning(deadline: Date)
        case native(NativeExecutionContext)
    }

    struct Ingress {
        let request: SafariRequest
        let canonicalData: Data
        let fingerprint: Data
        let authority: AuthorityVersion
        let replayOnly: Bool
    }

    final class OperationLease: @unchecked Sendable {
        let fileURL: URL
        private let lock: CrossProcessFileLock
        private let stateLock = NSLock()
        private var consumed = false
        private var released = false

        init(fileURL: URL, lock: CrossProcessFileLock) {
            self.fileURL = fileURL
            self.lock = lock
        }

        func consume() -> Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !consumed, !released else { return false }
            consumed = true
            return true
        }

        func release() {
            stateLock.lock()
            guard !released else {
                stateLock.unlock()
                return
            }
            released = true
            stateLock.unlock()
            lock.release()
        }
        deinit { release() }
    }

    struct ApprovalClaim: Equatable, Sendable {
        let handle: Handle
        fileprivate let value: UUID
        let lease: OperationLease?
        let executionDeadline: Date

        init(handle: Handle, value: UUID, lease: OperationLease? = nil, executionDeadline: Date) {
            self.handle = handle
            self.value = value
            self.lease = lease
            self.executionDeadline = executionDeadline
        }

        func matches(handle: Handle, value: UUID) -> Bool {
            self.handle == handle && self.value == value
        }

        func releaseLease() { lease?.release() }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.handle == rhs.handle && lhs.value == rhs.value
        }
    }

    struct ExecutionPermit: Equatable, Sendable {
        let handle: Handle
        fileprivate let value: UUID
        let lease: OperationLease?

        init(handle: Handle, value: UUID, lease: OperationLease? = nil) {
            self.handle = handle
            self.value = value
            self.lease = lease
        }

        func matches(handle: Handle, value: UUID) -> Bool {
            self.handle == handle && self.value == value
        }

        func releaseLease() { lease?.release() }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.handle == rhs.handle && lhs.value == rhs.value
        }
    }

    struct NativeApprovalAuthorization: Equatable, Sendable {
        let receipt: NativeDeliveryReceipt
        let decision: DappApprovalDecision
        let approvedAt: Date
    }

    struct NativeExecutionClaim: Equatable, Sendable {
        let approvalClaim: ApprovalClaim
        let approvedAt: Date
        let executionContext: NativeExecutionContext
    }

    enum AdmissionKind: Equatable, Sendable {
        case new, replay, coalesced
    }

    enum EnqueueResult {
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

    enum AdmissionDeadlineDisposition: Equatable {
        case admissible, expired, invalid
    }

    enum DappIngressResult { case accepted(Ingress), payloadTooLarge, invalid }
    enum SnapshotResult { case found(Snapshot), missing, unavailable }
    enum SnapshotsResult { case available([Handle: Snapshot]), unavailable }

    enum ApprovalClaimResult: Equatable {
        case claimed(ApprovalClaim), executing, responded, missing, unavailable
    }

    enum NativeExecutionClaimResult: Equatable {
        case claimed(NativeExecutionClaim)
        case ownershipLost, executing, responded, missing, unavailable
    }

    enum StoreMutationResult: Equatable {
        case persisted, ownershipLost, retryablePersistenceFailure
    }

    enum NativeInterruptionResult: Equatable {
        case interrupted, responseReady, ownershipLost, retryablePersistenceFailure
    }

    enum BeginExecutionResult: Equatable {
        case began(ExecutionPermit), ownershipLost, retryablePersistenceFailure
    }

    enum ResponseReadResult { case response([String: Any]), pending, missing, unavailable }
    enum ResponseStatusResult: Equatable { case pending, ready, missing, unavailable }

    static let workflowVersion = 4
    static let maximumPayloadBytes = 256 * 1024
    static let maximumRequestsPerHost = 4
    static let maximumRequests = 8
    static let maximumRetainedRequests = 16
    static let maximumRetainedRequestsPerOrigin = 12
    static let maximumGlobalRetainedRequests = maximumRetainedRequests
    static let maximumManualSwitchResponseBytes = maximumPayloadBytes * 2
    static let maximumStoredRecordBytes = maximumPayloadBytes * 2
    static let maximumRetainedBytes = maximumRetainedRequests * maximumStoredRecordBytes
    static let maximumRetainedBytesPerOrigin =
        maximumRetainedRequestsPerOrigin * maximumStoredRecordBytes
    static let requestTTL: TimeInterval = 15 * 60
    static let admissionDeadlineFutureSkew: TimeInterval = 60
    static let responseExpiry: TimeInterval = 60 * 60
    static let privateBrowsingKey = "__bwPrivateBrowsing"

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
        var rawObject = rawObject
        let replayOnly: Bool
        if let value = rawObject.removeValue(forKey: "replayOnly") {
            guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
                  let flag = value as? Bool else { return .invalid }
            replayOnly = flag
        } else {
            replayOnly = false
        }
        let allowedFields = Set([
            "id", "name", "provider", "body", "host", "configurationKey",
            "favicon", "enqueueAttempt", "admissionDeadline", "authority",
            "workflowVersion",
        ])
        guard Set(rawObject.keys).isSubset(of: allowedFields),
              request.workflowVersion == workflowVersion,
              rawObject["workflowVersion"] as? Int == workflowVersion,
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
        correlationObject.removeValue(forKey: "favicon")
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
        value.count == 32 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
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
        guard rawValue == rawValue.lowercased(), rawValue.count == 36,
              let value = UUID(uuidString: rawValue),
              value.uuidString.lowercased() == rawValue else { return nil }
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
        configurationKey: String,
        manualOnly: Bool = false
    ) -> ResponseStatusResult {
        store.responseStatus(
            handle: handle, configurationKey: configurationKey,
            manualOnly: manualOnly
        )
    }

    func listManualSwitchRequests(
        profileIdentifier: UUID?
    ) -> ManualSwitchRequestsResult {
        store.listManualSwitchRequests(profileIdentifier: profileIdentifier)
    }

    func loadManualSwitch(
        handle: Handle,
        configurationKey: String
    ) -> SnapshotResult {
        store.loadManualSwitch(
            handle: handle,
            configurationKey: configurationKey
        )
    }

    func load(handle: Handle) -> SnapshotResult { store.load(handle: handle) }
    func claim(handle: Handle) -> ApprovalClaimResult { store.claim(handle: handle) }
    func claimNativeExecution(
        handle: Handle,
        nativeDeliveryNonce: NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        approvedAt: Date
    ) -> NativeExecutionClaimResult {
        store.claimNativeExecution(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtimeInstanceIdentifier,
            approvedAt: approvedAt
        )
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

    func completeNativeDelivery(
        handle: Handle,
        nativeDeliveryNonce: NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        response: ResponseToExtension
    ) -> StoreMutationResult {
        store.completeNativeDelivery(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtimeInstanceIdentifier,
            response: response
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

    func release(claim: ApprovalClaim) -> StoreMutationResult { store.release(claim: claim) }

    func complete(handle: Handle, response: ResponseToExtension) -> StoreMutationResult {
        store.complete(handle: handle, response: response)
    }

    func reject(handle: Handle) -> StoreMutationResult {
        store.reject(handle: handle)
    }

    func begin(claim: ApprovalClaim) -> BeginExecutionResult {
        store.begin(claim: claim)
    }

    func prepareBroadcast(
        permit: ExecutionPermit,
        recoveryResponse: ResponseToExtension,
        authority: ExecutionAuthority
    ) -> StoreMutationResult {
        store.prepareBroadcast(
            permit: permit,
            recoveryResponse: recoveryResponse,
            authority: authority
        )
    }

    func complete(
        permit: ExecutionPermit,
        response: ResponseToExtension,
        authority: ExecutionAuthority
    ) -> StoreMutationResult {
        store.complete(
            permit: permit,
            response: response,
            authority: authority
        )
    }

    func rollback(
        permit: ExecutionPermit
    ) -> StoreMutationResult {
        store.rollback(permit: permit)
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

protocol PopupRequestStore: AnyObject {
    func authorityIsCurrent(handle: ExtensionBridge.Handle) async -> Bool
    func list(profileIdentifier: UUID?) async -> ExtensionBridge.SnapshotsResult
    func load(handle: ExtensionBridge.Handle) async -> ExtensionBridge.SnapshotResult
    func claim(handle: ExtensionBridge.Handle) async -> ExtensionBridge.ApprovalClaimResult
    func complete(handle: ExtensionBridge.Handle, response: ResponseToExtension) async -> ExtensionBridge.StoreMutationResult
    func reject(handle: ExtensionBridge.Handle) async -> ExtensionBridge.StoreMutationResult
    func release(claim: ExtensionBridge.ApprovalClaim) async -> ExtensionBridge.StoreMutationResult
    func begin(claim: ExtensionBridge.ApprovalClaim) async -> ExtensionBridge.BeginExecutionResult
    func prepareBroadcast(
        permit: ExtensionBridge.ExecutionPermit,
        recoveryResponse: ResponseToExtension,
        authority: ExtensionBridge.ExecutionAuthority
    ) async -> ExtensionBridge.StoreMutationResult
    func complete(
        permit: ExtensionBridge.ExecutionPermit,
        response: ResponseToExtension,
        authority: ExtensionBridge.ExecutionAuthority
    ) async -> ExtensionBridge.StoreMutationResult
    func rollback(
        permit: ExtensionBridge.ExecutionPermit
    ) async -> ExtensionBridge.StoreMutationResult
}

extension ExtensionBridge: PopupRequestStore {}

protocol NativeApprovalStore: PopupRequestStore {
    func claimNativeExecution(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        approvedAt: Date
    ) async -> ExtensionBridge.NativeExecutionClaimResult
}

extension ExtensionBridge: NativeApprovalStore {}
