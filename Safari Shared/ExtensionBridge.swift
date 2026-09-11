// ∅ 2026 lil org

import CryptoKit
import CoreFoundation
import Foundation

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
        let bundlePath: String
        let marketingVersion: String
        let buildVersion: String

        init?(
            bundleURL: URL,
            marketingVersion: String,
            buildVersion: String
        ) {
            bundlePath = bundleURL.standardizedFileURL.path
            self.marketingVersion = marketingVersion
            self.buildVersion = buildVersion
            guard isValid else { return nil }
        }

        var bundleURL: URL {
            URL(fileURLWithPath: bundlePath).standardizedFileURL
        }

        var isValid: Bool {
            !bundlePath.isEmpty && bundlePath.count <= 4_096 &&
                bundleURL.path == bundlePath &&
                bundleURL.pathExtension == "app" &&
                !marketingVersion.isEmpty && marketingVersion.count <= 128 &&
                !buildVersion.isEmpty && buildVersion.count <= 128
        }
    }

    struct NativeDeliveryReceipt: Codable, Equatable, Sendable {
        let nativeDeliveryNonce: NativeDeliveryNonce
        let runtimeInstanceIdentifier: UUID
        let owner: NativeDeliveryOwner?
    
        init(
            nativeDeliveryNonce: NativeDeliveryNonce,
            runtimeInstanceIdentifier: UUID,
            owner: NativeDeliveryOwner? = nil
        ) {
            self.nativeDeliveryNonce = nativeDeliveryNonce
            self.runtimeInstanceIdentifier = runtimeInstanceIdentifier
            self.owner = owner
        }

        func matches(
            nativeDeliveryNonce: NativeDeliveryNonce,
            runtimeInstanceIdentifier: UUID
        ) -> Bool {
            self.nativeDeliveryNonce == nativeDeliveryNonce &&
                self.runtimeInstanceIdentifier == runtimeInstanceIdentifier
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

    struct Snapshot {
        let handle: Handle
        let phase: Phase
        let request: SafariRequest?
        let nativeDecisionStaged: Bool
        let nativeDeliveryNonce: NativeDeliveryNonce
        let nativeDeliveryReceipt: NativeDeliveryReceipt?
        let nativeExecutionContext: NativeExecutionContext?
        let host: String
        let configurationKey: String
        let revisions: ProviderRevisions
        let createdAt: Date
        let enqueueAttempt: String
        let sequence: Int

        init(
            handle: Handle,
            phase: Phase,
            request: SafariRequest?,
            nativeDecisionStaged: Bool,
            nativeDeliveryNonce: NativeDeliveryNonce? = nil,
            nativeDeliveryReceipt: NativeDeliveryReceipt? = nil,
            nativeExecutionContext: NativeExecutionContext? = nil,
            host: String,
            configurationKey: String,
            revisions: ProviderRevisions,
            createdAt: Date,
            enqueueAttempt: String,
            sequence: Int
        ) {
            self.handle = handle
            self.phase = phase
            self.request = request
            self.nativeDecisionStaged = nativeDecisionStaged
            self.nativeDeliveryNonce = nativeDeliveryNonce ?? .init(
                value: handle.token.value
            )
            self.nativeDeliveryReceipt = nativeDeliveryReceipt
            self.nativeExecutionContext = nativeExecutionContext
            self.host = host
            self.configurationKey = configurationKey
            self.revisions = revisions
            self.createdAt = createdAt
            self.enqueueAttempt = enqueueAttempt
            self.sequence = sequence
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

        var json: [String: Any] {
            return ["ethereum": ethereum, "solana": solana]
        }

        private static func isValid(_ value: Int) -> Bool {
            return value >= 0 && value <= 9_007_199_254_740_991
        }
    }
    
    struct NativeExecutionContext: Codable, Equatable, Sendable {
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
        let revisions: ProviderRevisions
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

    final class NativeExecutionFence: @unchecked Sendable {
        let fileURL: URL
        let token: UUID
        private let lock: CrossProcessFileLock
        private let coordinationLock: CrossProcessFileLock
        private let coordinationPollNanoseconds: UInt64
        private let stateLock = NSLock()
        private var released = false

        init(
            fileURL: URL,
            token: UUID,
            lock: CrossProcessFileLock,
            coordinationLock: CrossProcessFileLock,
            coordinationPollNanoseconds: UInt64
        ) {
            self.fileURL = fileURL
            self.token = token
            self.lock = lock
            self.coordinationLock = coordinationLock
            self.coordinationPollNanoseconds = coordinationPollNanoseconds
        }

        func release() {
            stateLock.lock()
            guard !released else {
                stateLock.unlock()
                return
            }
            released = true
            stateLock.unlock()
            do {
                try coordinationLock.acquire(
                    timeoutNanoseconds: UInt64.max,
                    pollNanoseconds: coordinationPollNanoseconds
                )
                lock.release()
                coordinationLock.release()
            } catch {
                lock.release()
            }
        }

        deinit { release() }
    }

    struct ApprovalClaim: Equatable, Sendable {
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

    struct NativeDecisionClaim: Equatable, Sendable {
        let approvalClaim: ApprovalClaim
        let decision: NativeApprovalDecision
        let stagedAt: Date
        let executionContext: NativeExecutionContext?

        init(
            approvalClaim: ApprovalClaim,
            decision: NativeApprovalDecision,
            stagedAt: Date,
            executionContext: NativeExecutionContext? = nil
        ) {
            self.approvalClaim = approvalClaim
            self.decision = decision
            self.stagedAt = stagedAt
            self.executionContext = executionContext
        }
    }

    enum AdmissionKind: Equatable, Sendable {
        case new, replay
    }

    enum EnqueueResult {
        case accepted(
            handle: Handle,
            approvalRequired: Bool,
            revisions: ProviderRevisions,
            admissionKind: AdmissionKind,
            nativeDeliveryNonce: NativeDeliveryNonce
        )
        case expired, rejected, unavailable
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

    enum NativeDecisionClaimResult: Equatable {
        case claimed(NativeDecisionClaim)
        case notStaged, executing, responded, missing, unavailable
    }

    enum NativeExecutionContextResult: Equatable {
        case recorded(NativeExecutionContext)
        case pending, responseReady, missing, unavailable
    }

    enum StoreMutationResult: Equatable {
        case persisted, ownershipLost, retryablePersistenceFailure
    }

    enum BeginExecutionResult: Equatable {
        case began(ExecutionPermit), ownershipLost, retryablePersistenceFailure
    }

    enum ResponseReadResult { case response([String: Any]), pending, missing, unavailable }

    static let workflowVersion = 3
    static let maximumPayloadBytes = 256 * 1024
    static let maximumRequestsPerHost = 4
    static let maximumRequests = 8
    static let maximumRetainedRequests = 16
    static let maximumRetainedRequestsPerOrigin = 12
    static let maximumGlobalRetainedRequests = maximumRetainedRequests
    static let maximumStoredRecordBytes = maximumPayloadBytes * 2
    static let maximumRetainedBytes = maximumRetainedRequests * maximumStoredRecordBytes
    static let maximumRetainedBytesPerOrigin =
        maximumRetainedRequestsPerOrigin * maximumStoredRecordBytes
    static let requestTTL: TimeInterval = 15 * 60
    static let admissionDeadlineFutureSkew: TimeInterval = 60
    static let responseExpiry: TimeInterval = 60 * 60
    static let nativeExecutionTimeout: TimeInterval = 160
    static let approvalCommittedKey = "__bwApprovalCommitted"
    static let privateBrowsingKey = "__bwPrivateBrowsing"

    static let shared = ExtensionBridge(store: ExtensionRequestFileStore(
        rootURL: sharedRootURL
    ))

    private static var sharedRootURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedDefaults.suiteName
        )?
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("BigWalletExtensionBridge", isDirectory: true)
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
            "favicon", "enqueueAttempt", "admissionDeadline", "revisions",
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
              let revisions = ProviderRevisions(rawValue: rawObject["revisions"]),
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
            revisions: revisions,
            replayOnly: replayOnly
        ))
    }

    static func correlationFingerprint(_ rawObject: [String: Any]) -> Data? {
        var correlationObject = rawObject
        correlationObject.removeValue(forKey: "favicon")
        correlationObject.removeValue(forKey: "revisions")
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
        subject: InternalSafariRequest.Subject,
        byteCount: Int
    ) -> Bool {
        guard byteCount >= 0 else { return false }
        if case .page(.rpc) = subject { return true }
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

    func list(profileIdentifier: UUID?) -> SnapshotsResult {
        store.list(profileIdentifier: profileIdentifier)
    }

    func load(handle: Handle) -> SnapshotResult { store.load(handle: handle) }
    func claim(handle: Handle) -> ApprovalClaimResult { store.claim(handle: handle) }
    func claimExecutableNativeDecision(
        handle: Handle
    ) -> NativeDecisionClaimResult {
        store.claimExecutableNativeDecision(handle: handle)
    }

    func acquireNativeExecutionFence(
        handle: Handle,
        token: UUID
    ) -> NativeExecutionFence? {
        store.acquireNativeExecutionFence(handle: handle, token: token)
    }

    func nativeExecutionFenceIsHeld(
        handle: Handle,
        token: UUID
    ) -> Bool {
        store.nativeExecutionFenceIsHeld(handle: handle, token: token)
    }

    func recordNativeExecutionContext(
        handle: Handle,
        configurationKey: String,
        revisions: ProviderRevisions,
        executionDeadline: Date,
        fenceToken: UUID
    ) -> NativeExecutionContextResult {
        store.recordNativeExecutionContext(
            handle: handle,
            configurationKey: configurationKey,
            revisions: revisions,
            executionDeadline: executionDeadline,
            fenceToken: fenceToken
        )
    }

    func clearNativeExecutionContext(
        handle: Handle,
        expected: NativeExecutionContext
    ) -> StoreMutationResult {
        store.clearNativeExecutionContext(
            handle: handle,
            expected: expected
        )
    }

    func stageNativeDecision(
        handle: Handle,
        decision: NativeApprovalDecision
    ) -> StoreMutationResult {
        store.stageNativeDecision(handle: handle, decision: decision)
    }

    func stageNativeDecision(
        handle: Handle,
        nativeDeliveryNonce: NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        decision: NativeApprovalDecision
    ) -> StoreMutationResult {
        store.stageNativeDecision(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtimeInstanceIdentifier,
            decision: decision
        )
    }

    func recordNativeDeliveryReceipt(
        handle: Handle,
        nativeDeliveryNonce: NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID
    ) -> StoreMutationResult {
        store.recordNativeDeliveryReceipt(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtimeInstanceIdentifier
        )
    }

    func recordNativeDeliveryReceipt(
        handle: Handle,
        nativeDeliveryNonce: NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        owner: NativeDeliveryOwner
    ) -> StoreMutationResult {
        store.recordNativeDeliveryReceipt(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtimeInstanceIdentifier,
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

    func readResponse(
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
        return store.readResponse(handle: handle, configurationKey: configurationKey)
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
    func claimExecutableNativeDecision(
        handle: ExtensionBridge.Handle
    ) async -> ExtensionBridge.NativeDecisionClaimResult
    func stageNativeDecision(
        handle: ExtensionBridge.Handle,
        decision: NativeApprovalDecision
    ) async -> ExtensionBridge.StoreMutationResult
}

extension ExtensionBridge: NativeApprovalStore {}
