import Foundation
import XCTest
import WalletDomain
@testable import WalletAuthority
#if SWIFT_PACKAGE
import WalletRuntimeTestSupport
#endif

@MainActor
enum NativeApprovalTestAuthorization {
    static let authorityID = UUID()

    static func grant(_ challenge: WalletAuthenticationChallenge? = nil) -> WalletAuthenticationGrant {
        let challenge = challenge ?? WalletAuthenticationChallenge(authorityID: authorityID,
            purpose: .walletAccess(UUID()), deadline: .distantFuture)
        return challenge.issueGrant(for: challenge.authorityID, credentialIdentity: .init(status: { .current }))!
    }

    static func accessSession() -> WalletAccessSession {
        grant().accessSession(authorityID: authorityID)!
    }
}

@MainActor
extension NativeApprovalCoordinatorTests {
    @MainActor
    final class ScheduledWaits {
        private(set) var delays = [UInt64]()
        var gates = [Int: TestGate<Void>]()
        var registrations = [(Int, XCTestExpectation)]()
        var onReturned: ((Int) -> Void)?

        func wait(_ delay: UInt64) async {
            let index = delays.count
            let gate = TestGate<Void>()
            delays.append(delay)
            gates[index] = gate
            let ready = registrations.filter { delays.count >= $0.0 }
            registrations.removeAll { delays.count >= $0.0 }
            ready.forEach { $0.1.fulfill() }
            await gate.wait()
            onReturned?(index)
        }
        func observe(count: Int, expectation: XCTestExpectation) {
            if delays.count >= count { expectation.fulfill() }
            else { registrations.append((count, expectation)) }
        }
        func resume(_ index: Int) { gates.removeValue(forKey: index)?.resolve(()) }
        func isPending(_ index: Int) -> Bool { gates[index] != nil }
        func resumeAll() {
            let pending = Array(gates.values)
            gates.removeAll()
            pending.forEach { $0.resolve(()) }
        }
    }


    @MainActor
    final class CoordinatorStore: NativeDeliveryStore {
        var outstandingWrites = 0
        private(set) var maximumOutstandingWrites = 0
        var onRead: (() -> Void)?
        var onWrite: (() -> Void)?
        var onLoadReturned: (() -> Void)?
        var snapshot: ExtensionBridge.Snapshot?
        var loadHandler: (@MainActor (RequestHandle) async ->
            ExtensionBridge.SnapshotResult)?
        var recordCount = 0
        var recordedOwner: NativeDeliveryOwner?
        var recordHandler: (@MainActor (
            RequestHandle,
            NativeDeliveryNonce,
            NativeDeliveryOwner
        ) async -> ExtensionBridge.StoreMutationResult)?
        var unownedRejectHandler: @MainActor (RequestHandle) async ->
            ExtensionBridge.StoreMutationResult = { _ in .persisted }
        var completeHandler: @MainActor (
            RequestHandle,
            NativeDeliveryNonce,
            UUID,
            ImmediateResolution
        ) async -> ExtensionBridge.StoreMutationResult = { _, _, _, _ in
            .ownershipLost
        }
        var rejectHandler: @MainActor (
            RequestHandle,
            NativeDeliveryNonce,
            UUID
        ) async -> ExtensionBridge.StoreMutationResult = { _, _, _ in
            .ownershipLost
        }

        @MainActor
        func load(
            handle: RequestHandle
        ) async -> ExtensionBridge.SnapshotResult {
            onRead?()
            defer { onLoadReturned?() }
            if let loadHandler { return await loadHandler(handle) }
            return snapshot.map(ExtensionBridge.SnapshotResult.found) ?? .missing
        }

        @MainActor
        func recordNativeDeliveryReceipt(
            handle: RequestHandle,
            nativeDeliveryNonce: NativeDeliveryNonce,
            owner: NativeDeliveryOwner
        ) async -> ExtensionBridge.StoreMutationResult {
            beginWrite()
            defer { outstandingWrites -= 1 }
            recordCount += 1
            recordedOwner = owner
            if let recordHandler {
                return await recordHandler(
                    handle, nativeDeliveryNonce, owner
                )
            }
            guard case .found(let current) = await load(handle: handle),
                  case .queued(let request, _) = current.state,
                  current.nativeDeliveryNonce == nativeDeliveryNonce else {
                return .ownershipLost
            }
            let receipt = NativeDeliveryReceipt(
                nativeDeliveryNonce: nativeDeliveryNonce,
                owner: owner
            )
            if let existing = current.nativeDeliveryReceipt {
                return existing == receipt ? .persisted : .ownershipLost
            }
            guard loadHandler == nil else { return .ownershipLost }
            snapshot = ExtensionBridge.Snapshot(
                handle: current.handle,
                state: .queued(request: request, approval: .delivered(receipt)),
                nativeDeliveryNonce: current.nativeDeliveryNonce,
                host: current.host,
                configurationKey: current.configurationKey,
                revisions: current.revisions,
                createdAt: current.createdAt,
                enqueueAttempt: current.enqueueAttempt,
                sequence: current.sequence,
                requestBinding: current.requestBinding
            )
            return .persisted
        }

        @MainActor
        func reject(handle: RequestHandle) async ->
            ExtensionBridge.StoreMutationResult {
            beginWrite()
            defer { outstandingWrites -= 1 }
            return await unownedRejectHandler(handle)
        }

        private(set) var interruptionCount = 0
        var interruptionHandler: (@MainActor () async -> ExtensionBridge.NativeInterruptionResult)?

        @MainActor
        func interruptNativeApproval(
            handle: RequestHandle,
            nativeDeliveryNonce: NativeDeliveryNonce,
            runtimeInstanceIdentifier: UUID
        ) async -> ExtensionBridge.NativeInterruptionResult {
            beginWrite()
            defer { outstandingWrites -= 1 }
            interruptionCount += 1
            if let interruptionHandler { return await interruptionHandler() }
            return .interrupted
        }

        @MainActor
        func completeNativeImmediate(
            handle: RequestHandle,
            nativeDeliveryNonce: NativeDeliveryNonce,
            runtimeInstanceIdentifier: UUID,
            resolution: ImmediateResolution
        ) async -> ExtensionBridge.StoreMutationResult {
            beginWrite()
            defer { outstandingWrites -= 1 }
            return await completeHandler(
                handle,
                nativeDeliveryNonce,
                runtimeInstanceIdentifier,
                resolution
            )
        }

        @MainActor
        func rejectNativeDelivery(
            handle: RequestHandle,
            nativeDeliveryNonce: NativeDeliveryNonce,
            runtimeInstanceIdentifier: UUID
        ) async -> ExtensionBridge.StoreMutationResult {
            beginWrite()
            defer { outstandingWrites -= 1 }
            return await rejectHandler(
                handle,
                nativeDeliveryNonce,
                runtimeInstanceIdentifier
            )
        }

        @MainActor
        func beginWrite() {
            onWrite?()
            outstandingWrites += 1
            maximumOutstandingWrites = max(maximumOutstandingWrites, outstandingWrites)
        }
    }


    @MainActor
    final class ReviewTeardownParticipant: NativeApprovalReviewTeardown {
        var onInvalidate: (() -> Void)?

        func invalidateNativeApprovalReview() {
            onInvalidate?()
        }
    }


    func expectNoFurtherWork(
        events: Events,
        store: CoordinatorStore,
        returned: XCTestExpectation,
        release: () -> Void
    ) async {
        let unexpected = expectation(description: "retired work must not read, write, or publish")
        unexpected.isInverted = true
        let previousEvent = events.onRecord
        let previousRead = store.onRead
        let previousWrite = store.onWrite
        events.onRecord = { previousEvent?(); unexpected.fulfill() }
        store.onRead = { previousRead?(); unexpected.fulfill() }
        store.onWrite = { previousWrite?(); unexpected.fulfill() }
        defer {
            events.onRecord = previousEvent
            store.onRead = previousRead
            store.onWrite = previousWrite
        }
        release()
        await fulfillment(of: [returned], timeout: 2)
        await fulfillment(of: [unexpected], timeout: 0.1)
    }


    func waitForScheduledWait(
        _ waits: ScheduledWaits,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let registered = expectation(description: "scheduled wait registered")
        waits.observe(count: count, expectation: registered)
        await fulfillment(of: [registered], timeout: 2)
        XCTAssertGreaterThanOrEqual(waits.delays.count, count, file: file, line: line)
    }


    func nativeOwner(runtime: UUID) -> NativeDeliveryOwner {
        .init(
            runtimeInstanceIdentifier: runtime,
            processIdentifier: 42,
            processStartDate: Date(timeIntervalSince1970: 1_800_000_000),
            bundleURL: URL(fileURLWithPath: "/tmp/Big Wallet.app"),
            marketingVersion: "1.0.99",
            buildVersion: "148"
        )!
    }


    @MainActor
    final class Events {
        var onRecord: (() -> Void)?
        var authenticationCount = 0
        var presentations = [NativeApprovalCoordinator.Presentation]()

        func record(_ event: NativeApprovalCoordinator.Event, coordinator: NativeApprovalCoordinator?) {
            onRecord?()
            switch event {
            case .authenticationRequired: authenticationCount += 1
            case .presentationChanged:
                if let snapshot = coordinator?.currentPresentation {
                    presentations.append(snapshot.presentation)
                }
            }
        }
    }


    struct Fixture {
        let coordinator: NativeApprovalCoordinator
        let store: CoordinatorStore
        let runtime: UUID
        let key: ApprovalRouteKey
        let clock: TestClock
        let events: Events
    }


    func makeFixture(
        key: ApprovalRouteKey? = nil,
        createdAt: TimeInterval = 1_800_000_000,
        sequence: Int = 0,
        clock: TestClock = TestClock(uptimeNanoseconds: 0),
        environment: NativeApprovalCoordinator.Environment? = nil,
        requestAction: DappRequestAction? = nil,
        attemptNativeDecision: @escaping @MainActor @Sendable (
            ReviewConsent
        ) async -> NativeApprovalFinalizationResult = { _ in .pending }
    ) throws -> Fixture {
        let key = key ?? approvalKey(id: 100)
        let store = CoordinatorStore()
        store.snapshot = try approvalSnapshot(
            handle: key.handle,
            nonce: key.nativeDeliveryNonce,
            deadline: clock.date.addingTimeInterval(300),
            createdAt: Date(timeIntervalSince1970: createdAt),
            sequence: sequence,
            action: requestAction
        )
        let action = accountSelectionAction()
        let coordinator = NativeApprovalCoordinator(
            handle: key.handle,
            nativeDeliveryNonce: key.nativeDeliveryNonce,
            store: store,
            environment: environment ?? .init(
                now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
                uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
                wait: { _ in try? await TestDeferred<Void>().value() },
                prepare: { binding, _ in self.approvalPreparation(binding, action: action) },
                attemptNativeDecision: attemptNativeDecision
            )
        )
        let events = Events()
        coordinator.onEvent = { [weak coordinator] in events.record($0, coordinator: coordinator) }
        return Fixture(
            coordinator: coordinator,
            store: store,
            runtime: UUID(),
            key: key,
            clock: clock,
            events: events
        )
    }


    func start(_ fixture: Fixture) {
        fixture.coordinator.start(
            nativeDeliveryOwner: nativeOwner(runtime: fixture.runtime)
        )
    }


    func presentedReview(_ coordinator: NativeApprovalCoordinator) throws -> NativeApprovalReview {
        let presentation = try XCTUnwrap(coordinator.currentPresentation?.presentation)
        guard case .approval(let review) = presentation else {
            XCTFail("Expected an active native review")
            throw CocoaError(.coderInvalidValue)
        }
        return review
    }


    func ownedSnapshot(
        _ fixture: Fixture,
        runtime: UUID? = nil,
        phase: RequestPhase = .queued
    ) throws -> ExtensionBridge.Snapshot {
        try approvalSnapshot(
            handle: fixture.key.handle,
            nonce: fixture.key.nativeDeliveryNonce,
            deadline: fixture.clock.date.addingTimeInterval(300),
            receipt: .init(
                nativeDeliveryNonce: fixture.key.nativeDeliveryNonce,
                owner: nativeOwner(runtime: runtime ?? fixture.runtime)
            ),
            phase: phase
        )
    }


    func waitForCondition(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        await expectEventually(file: file, line: line, condition)
    }


    func waitForState(
        _ coordinator: NativeApprovalCoordinator,
        _ expected: NativeApprovalCoordinator.Phase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await expectEventually(file: file, line: line) { coordinator.phase == expected }
    }


    func loadPreparedPresentation(
        _ coordinator: NativeApprovalCoordinator,
        runtime: UUID
    ) async -> NativeApprovalCoordinator.Presentation {
        let ready = expectation(description: "prepared presentation")
        var presentation: NativeApprovalCoordinator.Presentation?
        let observer = coordinator.onEvent
        coordinator.onEvent = { [weak coordinator] event in
            observer?(event)
            switch event {
            case .authenticationRequired:
                coordinator?.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
            case .presentationChanged:
                if presentation == nil, let snapshot = coordinator?.currentPresentation {
                    if case .waiting = snapshot.presentation { return }
                    presentation = snapshot.presentation
                    ready.fulfill()
                }
            }
        }
        coordinator.start(
            nativeDeliveryOwner: nativeOwner(runtime: runtime)
        )
        await fulfillment(of: [ready], timeout: 1)
        return presentation ?? .finished
    }


    func approvalKey(
        id: Int,
        profileIdentifier: UUID? = nil
    ) -> ApprovalRouteKey {
        ApprovalRouteKey(
            handle: RequestHandle(
                id: id,
                token: .init(value: UUID()),
                profileIdentifier: profileIdentifier
            ),
            nativeDeliveryNonce: .init(value: UUID())
        )
    }


    func makeHandle(id: Int) -> RequestHandle {
        RequestHandle(
            id: id,
            token: .init(value: UUID()),
            profileIdentifier: nil
        )
    }


    func approvalPreparation(
        _ binding: ExtensionBridge.RequestBinding,
        action: DappRequestAction? = nil
    ) -> DappRequestPreparation {
        preparationForTesting(binding: binding, action: action ?? accountSelectionAction())
    }


    func accountSelectionAction() -> DappRequestAction {
        .selectAccount(.init(
            coinType: .ethereum,
            selectedAccounts: [],
            initiallyConnectedProviders: [],
            network: AuthorityTestNetworks.ethereum
        ))
    }


    func approvalSnapshot(
        handle: RequestHandle,
        nonce: NativeDeliveryNonce,
        deadline: Date,
        receipt: NativeDeliveryReceipt? = nil,
        phase: RequestPhase = .queued,
        createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        sequence: Int = 0,
        host: String = "wallet.example",
        action: DappRequestAction? = nil
    ) throws -> ExtensionBridge.Snapshot {
        let fixture = try ApprovedExecutionTestFixture(now: deadline.addingTimeInterval(-150))
        let name: String
        let body: [String: Any]
        switch action {
        case .approveMessage(let message):
            let account = WalletAccountDescriptor(walletID: message.walletId, account: message.account)
            try fixture.establishGrant(account, profileIdentifier: handle.profileIdentifier, configurationKey: "https://\(host)")
            guard case .signature(.ethereumPersonalMessage(let data)) = message.payload else {
                throw CocoaError(.coderInvalidValue)
            }
            name = "signPersonalMessage"
            body = ["address": account.normalizedAddress, "chainId": "0x1", "object": ["data": WalletEncoding.hexString(data: data)]]
        case .approveTransaction(let transaction):
            let account = WalletAccountDescriptor(walletID: transaction.walletId, account: transaction.account)
            try fixture.establishGrant(account, profileIdentifier: handle.profileIdentifier, configurationKey: "https://\(host)")
            var parameters: [String: Any] = [
                "from": transaction.transaction.from,
                "to": transaction.transaction.to,
                "data": transaction.transaction.data,
            ]
            parameters["value"] = transaction.transaction.value
            parameters["nonce"] = transaction.transaction.nonce
            parameters["gas"] = transaction.transaction.gas
            switch transaction.transaction.feeIntent {
            case .automatic:
                break
            case .legacy(let gasPrice):
                parameters["gasPrice"] = gasPrice?.toHexString(withPrefix: true)
            case .eip1559(let priority, let maximum):
                parameters["maxPriorityFeePerGas"] = priority?.toHexString(withPrefix: true)
                parameters["maxFeePerGas"] = maximum?.toHexString(withPrefix: true)
            }
            name = "signTransaction"
            body = ["address": account.normalizedAddress, "chainId": transaction.chain.chainIdHexString, "object": parameters]
        default:
            name = "requestAccounts"
            body = ["address": ""]
        }
        let stored = try fixture.enqueue(
            id: handle.id, name: name, provider: .ethereum,
            body: body, handle: handle, configurationKey: "https://\(host)"
        )
        let request = try XCTUnwrap(stored.request)
        let native: ExtensionBridge.Snapshot.NativeApproval? =
            phase == .approving && receipt != nil
                ? .init(receipt: receipt ?? .init(nativeDeliveryNonce: nonce, owner: nativeOwner(runtime: UUID())),
                        approvedAt: createdAt, executionContext: nil) : nil
        let state: ExtensionBridge.Snapshot.State
        switch phase {
        case .queued:
            state = .queued(
                request: request,
                approval: receipt.map { .delivered($0) } ?? .unowned
            )
        case .approving:
            state = .approving(request: request, nativeApproval: native)
        case .responded:
            state = .responded
        }
        return ExtensionBridge.Snapshot(
            handle: handle,
            state: state,
            nativeDeliveryNonce: nonce,
            host: request.host,
            configurationKey: request.configurationKey,
            revisions: ProviderRevisions(rawValue: [
                "ethereum": 0,
                "solana": 0,
            ])!,
            createdAt: createdAt,
            enqueueAttempt: request.enqueueAttempt,
            sequence: sequence,
            requestBinding: stored.requestBinding
        )
    }

}
