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
        let host: String
        let configurationKey: String
        let revisions: ProviderRevisions
        let createdAt: Date
        let enqueueAttempt: String
        let sequence: Int
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

    struct Ingress {
        let request: SafariRequest
        let canonicalData: Data
        let fingerprint: Data
        let revisions: ProviderRevisions
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
        var leaseFileURL: URL? { lease?.fileURL }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.handle == rhs.handle && lhs.value == rhs.value
        }
    }

    enum EnqueueResult {
        case accepted(
            handle: Handle,
            approvalRequired: Bool,
            revisions: ProviderRevisions
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
    static let requestTTL: TimeInterval = 15 * 60
    static let admissionDeadlineFutureSkew: TimeInterval = 60
    static let responseExpiry: TimeInterval = 60 * 60
    static let providerUpdateTTL = responseExpiry
    static let staleResponseKey = "__bwStale"
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
            revisions: revisions
        ))
    }

    static func correlationFingerprint(_ rawObject: [String: Any]) -> Data? {
        var correlationObject = rawObject
        correlationObject.removeValue(forKey: "favicon")
        correlationObject.removeValue(forKey: "revisions")
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
        recoveryResponse: ResponseToExtension
    ) -> StoreMutationResult {
        store.prepareBroadcast(permit: permit, recoveryResponse: recoveryResponse)
    }

    func complete(
        permit: ExecutionPermit,
        response: ResponseToExtension
    ) -> StoreMutationResult {
        store.complete(permit: permit, response: response)
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

}

protocol PopupRequestStore: AnyObject {
    func list(profileIdentifier: UUID?) async -> ExtensionBridge.SnapshotsResult
    func load(handle: ExtensionBridge.Handle) async -> ExtensionBridge.SnapshotResult
    func claim(handle: ExtensionBridge.Handle) async -> ExtensionBridge.ApprovalClaimResult
    func complete(handle: ExtensionBridge.Handle, response: ResponseToExtension) async -> ExtensionBridge.StoreMutationResult
    func reject(handle: ExtensionBridge.Handle) async -> ExtensionBridge.StoreMutationResult
    func release(claim: ExtensionBridge.ApprovalClaim) async -> ExtensionBridge.StoreMutationResult
    func begin(claim: ExtensionBridge.ApprovalClaim) async -> ExtensionBridge.BeginExecutionResult
    func prepareBroadcast(permit: ExtensionBridge.ExecutionPermit, recoveryResponse: ResponseToExtension) async -> ExtensionBridge.StoreMutationResult
    func complete(permit: ExtensionBridge.ExecutionPermit, response: ResponseToExtension) async -> ExtensionBridge.StoreMutationResult
}

extension ExtensionBridge: PopupRequestStore {}
