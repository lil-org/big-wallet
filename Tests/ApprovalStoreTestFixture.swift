import Foundation
import XCTest
@testable import Big_Wallet

private final class ApprovalStoreWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = 0

    func failNext() {
        lock.withLock { failures += 1 }
    }

    func write(_ data: Data, to url: URL) throws {
        let fails = lock.withLock {
            guard failures > 0 else { return false }
            failures -= 1
            return true
        }
        if fails { throw CocoaError(.fileWriteUnknown) }
        try ExtensionRequestFileStore.defaultAtomicWrite(data, url)
    }
}

actor ApprovalStoreTestFixture: NativeApprovalStore {
    let bridge: ExtensionBridge
    private let rootURL: URL
    private let clock: @Sendable () -> Date
    private let writes: ApprovalStoreWrites
    private var retainedClaims = [ExtensionBridge.ApprovalClaim]()
    private var executionReads = [ExtensionBridge.Handle: ExtensionBridge.NativeExecutionReadLease]()
    private var eventValues = [String]()
    private var loadCountValue = 0
    private var activeOperations = 0
    private var isClosing = false
    private var cleanupContinuation: CheckedContinuation<Void, Never>?
    private var nextClaimObserver: (@MainActor (ExtensionBridge.ApprovalClaim) -> Void)?
    private var nextRejectResult: ExtensionBridge.StoreMutationResult?
    private var nextReleaseResult: ExtensionBridge.StoreMutationResult?
    private var nextClaimResult: ExtensionBridge.ApprovalClaimResult?
    private var nextLoadTransform: ((ExtensionBridge.Snapshot) -> ExtensionBridge.Snapshot)?
    private var nextNativeClaimDate: Date?
    private var nextCompletionReceipt: ExtensionBridge.NativeDeliveryReceipt?
    private var shouldFailNextCompletion = false
    private var shouldFailNextBegin = false
    private var beginHook: (@MainActor () -> Void)?
    private var permitCompletionHook: (@Sendable () -> Void)?
    private var broadcastCheckpointHook: (@Sendable () -> Void)?
    private var committedCheckpoints = Set<ExtensionBridge.Handle>()
    private var suspendClaim = false
    private var claimContinuation: CheckedContinuation<Void, Never>?
    private var suspendCompletion = false
    private var completionContinuation: CheckedContinuation<ExtensionBridge.StoreMutationResult?, Never>?

    init(clock: @escaping @Sendable () -> Date = { Date() }) throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "approval-store-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        self.clock = clock
        let writes = ApprovalStoreWrites()
        self.writes = writes
        bridge = ExtensionBridge(store: ExtensionRequestFileStore(
            rootURL: rootURL,
            dependencies: .init(clock: clock, atomicWrite: writes.write)
        ))
    }

    func cleanup() async throws {
        isClosing = true
        resumeClaim()
        resumeCompletion(result: .ownershipLost)
        if activeOperations > 0 {
            await withCheckedContinuation { cleanupContinuation = $0 }
        }
        for claim in retainedClaims { _ = await bridge.release(claim: claim) }
        retainedClaims.removeAll()
        executionReads.values.forEach { $0.release() }
        executionReads.removeAll()
        try FileManager.default.removeItem(at: rootURL)
    }

    func enqueue(
        rawObject: [String: Any],
        profileIdentifier: UUID? = nil,
        revisions: ExtensionBridge.ProviderRevisions
    ) async throws -> ExtensionBridge.Snapshot {
        var rawObject = rawObject
        rawObject["admissionDeadline"] = Int(clock().addingTimeInterval(
            ExtensionBridge.requestTTL
        ).timeIntervalSince1970 * 1_000)
        rawObject["revisions"] = revisions.json
        let request = try XCTUnwrap(SafariRequest(json: rawObject))
        guard case .accepted(let ingress) = ExtensionBridge.dappIngressResult(
            request: request, rawObject: rawObject
        ) else { throw CocoaError(.coderInvalidValue) }
        guard case .accepted(let handle, _, _, _, _) = await bridge.enqueue(
            ingress: ingress, profileIdentifier: profileIdentifier
        ) else { throw CocoaError(.fileWriteUnknown) }
        return try await snapshot(handle: handle)
    }

    func snapshot(handle: ExtensionBridge.Handle) async throws -> ExtensionBridge.Snapshot {
        guard case .found(let value) = await bridge.load(handle: handle) else {
            throw CocoaError(.fileReadUnknown)
        }
        return value
    }

    func holdForeignClaim(handle: ExtensionBridge.Handle) async throws {
        guard case .claimed(let claim) = await bridge.claim(handle: handle) else {
            throw CocoaError(.fileWriteUnknown)
        }
        retainedClaims.append(claim)
    }

    func setNativeDeliveryReceipt(
        _ receipt: ExtensionBridge.NativeDeliveryReceipt?,
        handle: ExtensionBridge.Handle
    ) async {
        guard let snapshot = try? await snapshot(handle: handle) else {
            XCTFail("Missing receipt request")
            return
        }
        let result: ExtensionBridge.StoreMutationResult
        if let receipt {
            result = await bridge.recordNativeDeliveryReceipt(
                handle: handle,
                nativeDeliveryNonce: snapshot.nativeDeliveryNonce,
                owner: receipt.owner
            )
        } else if let receipt = snapshot.nativeDeliveryReceipt {
            result = await bridge.clearNativeDeliveryReceipt(
                handle: handle,
                nativeDeliveryNonce: receipt.nativeDeliveryNonce,
                runtimeInstanceIdentifier: receipt.owner.runtimeInstanceIdentifier
            )
        } else { return }
        XCTAssertEqual(result, .persisted)
    }

    func installNativeDecision(
        handle: ExtensionBridge.Handle,
        decision: DappApprovalDecision,
        stagedAt: Date? = nil
    ) async -> ExtensionBridge.StoreMutationResult {
        guard let snapshot = try? await snapshot(handle: handle) else { return .ownershipLost }
        let runtime = snapshot.nativeDeliveryReceipt?.owner.runtimeInstanceIdentifier ?? UUID()
        let owner = snapshot.nativeDeliveryReceipt?.owner ?? ExtensionBridge.NativeDeliveryOwner(
            runtimeInstanceIdentifier: runtime,
            processIdentifier: 42,
            processStartDate: clock(),
            bundleURL: rootURL.appendingPathComponent("Helper.app"),
            marketingVersion: "1.0.99", buildVersion: "148"
        )!
        let delivered = await bridge.recordNativeDeliveryReceipt(
            handle: handle, nativeDeliveryNonce: snapshot.nativeDeliveryNonce,
            owner: owner
        )
        guard delivered == .persisted else { return delivered }
        return await bridge.stageNativeDecision(
            handle: handle, nativeDeliveryNonce: snapshot.nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtime, decision: decision,
            approvedAt: stagedAt ?? clock()
        )
    }

    func installNativeExecutionRead(
        handle: ExtensionBridge.Handle,
        revisions: ExtensionBridge.ProviderRevisions,
        executionDeadline: Date
    ) async {
        releaseExecutionRead(handle: handle)
        guard let snapshot = try? await snapshot(handle: handle), snapshot.phase != .responded else { return }
        guard case .acquired(let lease) = await bridge.beginNativeExecutionRead(
            handle: handle,
            configurationKey: snapshot.configurationKey,
            revisions: revisions,
            executionDeadline: executionDeadline
        ) else {
            XCTFail("Expected executable native read")
            return
        }
        executionReads[handle] = lease
    }

    func releaseExecutionRead(handle: ExtensionBridge.Handle) {
        executionReads.removeValue(forKey: handle)?.release()
    }

    func transformNextLoad(_ transform: @escaping (ExtensionBridge.Snapshot) -> ExtensionBridge.Snapshot) {
        nextLoadTransform = transform
    }

    func overrideNextNativeClaimDate(_ date: Date) { nextNativeClaimDate = date }
    func events() -> [String] { eventValues }
    func loadCount() -> Int { loadCountValue }
    func record(_ event: String) { eventValues.append(event) }
    func completedErrorCode(handle: ExtensionBridge.Handle) async -> Int? {
        (await response(handle: handle)?["error"] as? [String: Any])?["code"] as? Int
    }
    func completedApprovalWasCommitted(handle: ExtensionBridge.Handle) async -> Bool {
        await response(handle: handle)?["approvalCommitted"] as? Bool == true
    }
    func checkpointApprovalWasCommitted(handle: ExtensionBridge.Handle) -> Bool {
        committedCheckpoints.contains(handle)
    }
    func response(handle: ExtensionBridge.Handle) async -> [String: Any]? {
        guard let snapshot = try? await snapshot(handle: handle),
              case .response(let response) = await bridge.readResponse(
                id: handle.id, configurationKey: snapshot.configurationKey,
                requestToken: handle.requestToken, profileIdentifier: handle.profileIdentifier
              ) else { return nil }
        return response
    }

    func observeNextClaim(_ observer: @escaping @MainActor (ExtensionBridge.ApprovalClaim) -> Void) {
        nextClaimObserver = observer
    }
    func forceNextRejectResult(_ result: ExtensionBridge.StoreMutationResult) { nextRejectResult = result }
    func forceNextReleaseResult(_ result: ExtensionBridge.StoreMutationResult) { nextReleaseResult = result }
    func forceNextClaimResult(_ result: ExtensionBridge.ApprovalClaimResult) { nextClaimResult = result }
    func forceNextCompletionOwnershipLoss(receipt: ExtensionBridge.NativeDeliveryReceipt) { nextCompletionReceipt = receipt }
    func failNextCompletion() { shouldFailNextCompletion = true }
    func failNextBegin() { shouldFailNextBegin = true }
    func setBeginHook(_ hook: @escaping @MainActor () -> Void) { beginHook = hook }
    func setPermitCompletionHook(_ hook: @escaping @Sendable () -> Void) { permitCompletionHook = hook }
    func setBroadcastCheckpointHook(_ hook: @escaping @Sendable () -> Void) { broadcastCheckpointHook = hook }
    func suspendNextClaim() { suspendClaim = true }
    func resumeClaim() {
        let continuation = claimContinuation
        claimContinuation = nil
        continuation?.resume()
    }
    func suspendNextCompletion() { suspendCompletion = true }
    func resumeCompletion(result: ExtensionBridge.StoreMutationResult? = nil) {
        let continuation = completionContinuation
        completionContinuation = nil
        continuation?.resume(returning: result)
    }

    func list(profileIdentifier: UUID?) async -> ExtensionBridge.SnapshotsResult {
        guard !isClosing else { return .unavailable }
        activeOperations += 1
        defer { finishOperation() }
        return await bridge.list(profileIdentifier: profileIdentifier)
    }
    func load(handle: ExtensionBridge.Handle) async -> ExtensionBridge.SnapshotResult {
        guard !isClosing else { return .unavailable }
        activeOperations += 1
        defer { finishOperation() }
        loadCountValue += 1
        let result = await bridge.load(handle: handle)
        if case .found(let snapshot) = result, let transform = nextLoadTransform {
            nextLoadTransform = nil
            return .found(transform(snapshot))
        }
        return result
    }
    func claim(handle: ExtensionBridge.Handle) async -> ExtensionBridge.ApprovalClaimResult {
        guard !isClosing else { return .unavailable }
        activeOperations += 1
        defer { finishOperation() }
        if let result = nextClaimResult {
            nextClaimResult = nil
            return result
        }
        if suspendClaim {
            suspendClaim = false
            await withCheckedContinuation { continuation in
                eventValues.append("claimStarted")
                claimContinuation = continuation
            }
        }
        guard !isClosing else { return .unavailable }
        let result = await bridge.claim(handle: handle)
        if case .claimed(let claim) = result {
            eventValues.append("claim")
            let observer = nextClaimObserver
            nextClaimObserver = nil
            await observer?(claim)
        }
        return result
    }
    func claimExecutableNativeDecision(handle: ExtensionBridge.Handle) async -> ExtensionBridge.NativeDecisionClaimResult {
        guard !isClosing else { return .unavailable }
        activeOperations += 1
        defer { finishOperation() }
        let result = await bridge.claimExecutableNativeDecision(handle: handle)
        guard case .claimed(let claim) = result else { return result }
        eventValues.append("nativeClaim")
        if let date = nextNativeClaimDate {
            nextNativeClaimDate = nil
            return .claimed(.init(approvalClaim: claim.approvalClaim, decision: claim.decision,
                                  stagedAt: date, executionContext: claim.executionContext))
        }
        return result
    }
    func complete(handle: ExtensionBridge.Handle, response: ResponseToExtension) async -> ExtensionBridge.StoreMutationResult {
        guard !isClosing else { return .ownershipLost }
        activeOperations += 1
        defer { finishOperation() }
        if let receipt = nextCompletionReceipt {
            nextCompletionReceipt = nil
            await setNativeDeliveryReceipt(receipt, handle: handle)
        }
        if let result = await beforeCompletion() { return result }
        let result = await bridge.complete(handle: handle, response: response)
        recordCompletion(result)
        return result
    }
    func reject(handle: ExtensionBridge.Handle) async -> ExtensionBridge.StoreMutationResult {
        guard !isClosing else { return .ownershipLost }
        activeOperations += 1
        defer { finishOperation() }
        eventValues.append("reject")
        if let result = nextRejectResult {
            nextRejectResult = nil
            return result
        }
        return await bridge.reject(handle: handle)
    }
    func release(claim: ExtensionBridge.ApprovalClaim) async -> ExtensionBridge.StoreMutationResult {
        guard !isClosing else { return .ownershipLost }
        activeOperations += 1
        defer { finishOperation() }
        eventValues.append("release")
        if let result = nextReleaseResult {
            nextReleaseResult = nil
            return result
        }
        return await bridge.release(claim: claim)
    }
    func begin(claim: ExtensionBridge.ApprovalClaim) async -> ExtensionBridge.BeginExecutionResult {
        guard !isClosing else { return .ownershipLost }
        activeOperations += 1
        defer { finishOperation() }
        eventValues.append("begin")
        await beginHook?()
        if shouldFailNextBegin {
            shouldFailNextBegin = false
            return .retryablePersistenceFailure
        }
        return await bridge.begin(claim: claim)
    }
    func complete(permit: ExtensionBridge.ExecutionPermit, response: ResponseToExtension,
                  authority: ExtensionBridge.ExecutionAuthority) async -> ExtensionBridge.StoreMutationResult {
        guard !isClosing else { return .ownershipLost }
        activeOperations += 1
        defer { finishOperation() }
        permitCompletionHook?()
        if let result = await beforeCompletion() { return result }
        let result = await bridge.complete(permit: permit, response: response, authority: authority)
        recordCompletion(result)
        return result
    }
    func prepareBroadcast(permit: ExtensionBridge.ExecutionPermit, recoveryResponse: ResponseToExtension,
                          authority: ExtensionBridge.ExecutionAuthority) async -> ExtensionBridge.StoreMutationResult {
        guard !isClosing else { return .ownershipLost }
        activeOperations += 1
        defer { finishOperation() }
        broadcastCheckpointHook?()
        let result = await bridge.prepareBroadcast(permit: permit, recoveryResponse: recoveryResponse, authority: authority)
        if result == .persisted {
            eventValues.append("checkpoint")
            if recoveryResponse.approvalCommitted {
                committedCheckpoints.insert(permit.handle)
            }
        }
        return result
    }
    func rollback(permit: ExtensionBridge.ExecutionPermit) async -> ExtensionBridge.StoreMutationResult {
        guard !isClosing else { return .ownershipLost }
        activeOperations += 1
        defer { finishOperation() }
        let result = await bridge.rollback(permit: permit)
        if result == .persisted { eventValues.append("rollback") }
        return result
    }

    private func finishOperation() {
        activeOperations -= 1
        if activeOperations == 0 {
            let continuation = cleanupContinuation
            cleanupContinuation = nil
            continuation?.resume()
        }
    }

    private func beforeCompletion() async -> ExtensionBridge.StoreMutationResult? {
        guard !isClosing else { return .ownershipLost }
        if suspendCompletion {
            suspendCompletion = false
            let result = await withCheckedContinuation { continuation in
                eventValues.append("completeStarted")
                completionContinuation = continuation
            }
            if let result {
                eventValues.append("completeResumed")
                return result
            }
        }
        if shouldFailNextCompletion {
            shouldFailNextCompletion = false
            writes.failNext()
        }
        return nil
    }

    private func recordCompletion(_ result: ExtensionBridge.StoreMutationResult) {
        switch result {
        case .persisted: eventValues.append("complete")
        case .retryablePersistenceFailure: eventValues.append("completeFailed")
        case .ownershipLost: break
        }
    }
}
