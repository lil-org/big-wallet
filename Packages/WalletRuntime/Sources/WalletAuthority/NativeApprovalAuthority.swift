import WalletDomain
// ∅ 2026 lil org

import Foundation

@MainActor
public protocol NativeApprovalReviewTeardown: AnyObject {
    func invalidateNativeApprovalReview()
}

@MainActor
public final class NativeApprovalReview {
    private struct Participant {
        weak var value: (any NativeApprovalReviewTeardown)?
    }

    let approval: ApprovalReview
    private let authorityID: UUID
    private let clock: @Sendable () -> Date
    private let authenticationScope = UUID()
    private let access: WalletAccessSession?
    private let receipt: NativeDeliveryReceipt?
    private let finalize: @MainActor @Sendable (ReviewConsent) async -> NativeApprovalFinalizationResult
    private var authenticationChallenge: WalletAuthenticationChallenge?
    public private(set) var isActive = true
    private var participants = [ObjectIdentifier: Participant]()

    public var request: SafariRequest { approval.request }
    public var handle: RequestHandle { approval.binding.handle }
    public var action: DappRequestAction { approval.action }

    init(intent: BoundApprovalIntent, authorityID: UUID = UUID(), clock: @escaping @Sendable () -> Date = Date.init, hooks: AuthorityExecutionHooks = .none,
         access: WalletAccessSession? = nil, receipt: NativeDeliveryReceipt? = nil,
         finalize: @escaping @MainActor @Sendable (ReviewConsent) async -> NativeApprovalFinalizationResult = { _ in .pending }) {
        self.access = access
        self.receipt = receipt
        self.finalize = finalize
        approval = ApprovalReview(intent: intent, hooks: hooks)
        self.authorityID = authorityID
        self.clock = clock
    }

    public func makeMessageAuthenticationChallenge(solanaCluster: Solana.Cluster?) -> WalletAuthenticationChallenge? {
        guard isActive, case .approveMessage(let action) = action,
              DappApprovalValidator.resolveMessagePayload(action.payload, cluster: solanaCluster, endpoints: action.solanaEndpoints) != nil else { return nil }
        return makeChallenge(.message(review: authenticationScope, cluster: solanaCluster))
    }

    public func makeTransactionAuthenticationChallenge(
        transaction: Transaction,
        reviewedNetwork: ResolvedEthereumNetwork
    ) -> WalletAuthenticationChallenge? {
        guard isActive, case .approveTransaction(let action) = action,
              TransactionReviewBinding.preservesPayload(transaction, reviewed: action.transaction),
              let execution = DappApprovalDecision.TransactionExecution(
                transaction, reviewedNetwork: reviewedNetwork,
                approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account)
              ), execution.isApplicable(to: action) else { return nil }
        return makeChallenge(.transaction(review: authenticationScope, binding: .init(execution)))
    }

    private func makeChallenge(_ purpose: WalletAuthenticationChallenge.Purpose) -> WalletAuthenticationChallenge {
        authenticationChallenge?.invalidate()
        let challenge = WalletAuthenticationChallenge(
            authorityID: authorityID, purpose: purpose, deadline: request.admissionDeadline, clock: clock
        )
        authenticationChallenge = challenge
        return challenge
    }

    private func consumeMessageAuthorization(_ grant: WalletAuthenticationGrant, cluster: Solana.Cluster?) -> Bool {
        isActive && grant.consume(authorityID: authorityID, purpose: .message(review: authenticationScope, cluster: cluster))
    }

    private func consumeTransactionAuthorization(_ grant: WalletAuthenticationGrant, execution: DappApprovalDecision.TransactionExecution) -> Bool {
        isActive && grant.consume(authorityID: authorityID, purpose: .transaction(review: authenticationScope, binding: .init(execution)))
    }

    public func approveAccounts(_ accounts: [SpecificWalletAccount], ethereumNetwork: EthereumNetwork?) -> NativeApprovalOperation? {
        let identities = accounts.map { WalletAccountDescriptor(walletID: $0.walletId, account: $0.account) }
        return accept { approval, approvedAt, receipt in
            approval.acceptAccounts(selection: .init(accounts: identities, ethereumChainID: ethereumNetwork?.chainIdHexString),
                                    approvedAt: approvedAt, nativeReceipt: receipt)
        }
    }

    public func approveMessage(solanaCluster: Solana.Cluster?, authorization: WalletAuthenticationGrant) -> NativeApprovalOperation? {
        guard canAccept, consumeMessageAuthorization(authorization, cluster: solanaCluster) else { return nil }
        return accept { approval, approvedAt, receipt in
            approval.acceptMessage(cluster: solanaCluster, approvedAt: approvedAt, nativeReceipt: receipt)
        }
    }

    public func approveTransaction(_ transaction: Transaction, reviewedNetwork: ResolvedEthereumNetwork,
                                   authorization: WalletAuthenticationGrant) -> NativeApprovalOperation? {
        guard canAccept, case .approveTransaction(let action) = action,
              TransactionReviewBinding.preservesPayload(transaction, reviewed: action.transaction),
              let execution = DappApprovalDecision.TransactionExecution(transaction, reviewedNetwork: reviewedNetwork,
                  approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account)),
              execution.isApplicable(to: action), consumeTransactionAuthorization(authorization, execution: execution) else {
            authorization.invalidate()
            return nil
        }
        return accept { approval, approvedAt, receipt in
            approval.acceptTransaction(execution: execution, approvedAt: approvedAt, nativeReceipt: receipt)
        }
    }

    public func approveAddEthereumChain() -> NativeApprovalOperation? {
        accept { approval, approvedAt, receipt in
            approval.acceptAddEthereumChain(approvedAt: approvedAt, nativeReceipt: receipt)
        }
    }

    private var canAccept: Bool {
        isActive && clock() < request.admissionDeadline && access?.validateCredentials(for: authorityID) == true
    }

    private func accept(_ decision: (ApprovalReview, Date, NativeDeliveryReceipt) -> ReviewConsent?) -> NativeApprovalOperation? {
        guard canAccept, let receipt,
              let consent = decision(approval, clock(), receipt) else { return nil }
        return NativeApprovalOperation(consent: consent, finalize: finalize)
    }

    public func register(_ participant: any NativeApprovalReviewTeardown) {
        guard isActive else {
            participant.invalidateNativeApprovalReview()
            return
        }
        participants = participants.filter { $0.value.value != nil }
        participants[ObjectIdentifier(participant)] = Participant(value: participant)
    }

    public func invalidate() {
        guard isActive else { return }
        isActive = false
        authenticationChallenge?.invalidate()
        authenticationChallenge = nil
        approval.invalidate()
        let activeParticipants = participants.values.compactMap(\.value)
        participants.removeAll()
        for participant in activeParticipants {
            participant.invalidateNativeApprovalReview()
        }
    }
}

public protocol NativeDeliveryStore: AnyObject, Sendable {
    func load(
        handle: RequestHandle
    ) async -> ExtensionBridge.SnapshotResult
    func recordNativeDeliveryReceipt(
        handle: RequestHandle,
        nativeDeliveryNonce: NativeDeliveryNonce,
        owner: NativeDeliveryOwner
    ) async -> ExtensionBridge.StoreMutationResult
    func reject(handle: RequestHandle) async ->
        ExtensionBridge.StoreMutationResult
    func interruptNativeApproval(
        handle: RequestHandle,
        nativeDeliveryNonce: NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID
    ) async -> ExtensionBridge.NativeInterruptionResult
    func rejectNativeDelivery(
        handle: RequestHandle,
        nativeDeliveryNonce: NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID
    ) async -> ExtensionBridge.StoreMutationResult
}

protocol NativeImmediateCompleting: Sendable {
    func completeNativeImmediate(
        handle: RequestHandle,
        nativeDeliveryNonce: NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        resolution: ImmediateResolution
    ) async -> ExtensionBridge.StoreMutationResult
}

extension ExtensionBridge: NativeDeliveryStore, NativeImmediateCompleting {}


@MainActor
public final class NativeApprovalOperation {
    public enum Result: Equatable, Sendable { case responseReady, interruptionRequired, reviewRequired, pending }
    private let consent: ReviewConsent
    private let finalize: @MainActor @Sendable (ReviewConsent) async -> NativeApprovalFinalizationResult

    fileprivate init(consent: ReviewConsent, finalize: @escaping @MainActor @Sendable (ReviewConsent) async -> NativeApprovalFinalizationResult) {
        self.consent = consent
        self.finalize = finalize
    }

    public func attempt() async -> Result {
        switch await finalize(consent) {
        case .responseReady: .responseReady
        case .interruptionRequired: .interruptionRequired
        case .reviewRequired: .reviewRequired
        case .pending: .pending
        }
    }
}

@MainActor
public final class NativeApprovalResponse {
    private let persist: @MainActor @Sendable () async -> ExtensionBridge.StoreMutationResult

    fileprivate init(persist: @escaping @MainActor @Sendable () async -> ExtensionBridge.StoreMutationResult) {
        self.persist = persist
    }

    public func persistResponse() async -> ExtensionBridge.StoreMutationResult { await persist() }
}

@MainActor
public final class NativeApprovalAuthority {
    public enum Preparation: Sendable {
        case review(NativeApprovalReview)
        case immediate(NativeApprovalResponse)
        case unavailable, changed, retry
    }

    struct Environment: Sendable {
        let messages: AuthorityMessages
        let authorityID: UUID
        let hooks: AuthorityExecutionHooks
        let now: @Sendable () -> Date
        let uptime: @MainActor @Sendable () -> TimeInterval
        let wait: @MainActor @Sendable (UInt64) async -> Void
        let waitForAuthenticationExpiry: @MainActor @Sendable (TimeInterval) async throws -> Void
        let prepare: @MainActor @Sendable (ExtensionBridge.RequestBinding, WalletReviewCatalog?) -> DappRequestPreparation
        let reloadWallets: @MainActor @Sendable () async -> Bool
        let currentReviewCatalog: @MainActor @Sendable () -> WalletReviewCatalog?
        let attemptNativeDecision: @MainActor @Sendable (ReviewConsent) async -> NativeApprovalFinalizationResult

        init(
            now: @escaping @Sendable () -> Date,
            messages: AuthorityMessages = .testingEnglish,
            authorityID: UUID = UUID(),
            hooks: AuthorityExecutionHooks = .none,
            uptime: (@MainActor @Sendable () -> TimeInterval)? = nil,
            wait: @escaping @MainActor @Sendable (UInt64) async -> Void,
            waitForAuthenticationExpiry: (@MainActor @Sendable (TimeInterval) async throws -> Void)? = nil,
            prepare: (@MainActor @Sendable (ExtensionBridge.RequestBinding, WalletReviewCatalog?) -> DappRequestPreparation)? = nil,
            reloadWallets: (@MainActor @Sendable () async -> Bool)? = nil,
            currentReviewCatalog: (@MainActor @Sendable () -> WalletReviewCatalog?)? = nil,
            attemptNativeDecision: (@MainActor @Sendable (ReviewConsent) async -> NativeApprovalFinalizationResult)? = nil
        ) {
            self.now = now
            self.messages = messages
            self.authorityID = authorityID
            self.hooks = hooks
            self.uptime = uptime ?? { ProcessInfo.processInfo.systemUptime }
            self.wait = wait
            self.waitForAuthenticationExpiry = waitForAuthenticationExpiry ?? { seconds in
                let clock = ContinuousClock()
                try await clock.sleep(until: clock.now.advanced(by: .seconds(seconds)), tolerance: nil)
            }
            self.prepare = prepare ?? { _, _ in .unavailable }
            self.reloadWallets = reloadWallets ?? { false }
            self.currentReviewCatalog = currentReviewCatalog ?? { nil }
            self.attemptNativeDecision = attemptNativeDecision ?? { _ in .pending }
        }

        static func live(
            processor: DappRequestProcessor,
            wallets: WalletsManager,
            finalizer: NativeApprovalFinalizer,
            messages: AuthorityMessages,
            authorityID: UUID,
            clock: @escaping @Sendable () -> Date,
            hooks: AuthorityExecutionHooks
        ) -> Environment {
            Environment(
                now: clock,
                messages: messages,
                authorityID: authorityID,
                hooks: hooks,
                wait: { nanoseconds in
                    let clock = ContinuousClock()
                    try? await clock.sleep(until: clock.now.advanced(by: .nanoseconds(Int64(clamping: nanoseconds))), tolerance: nil)
                },
                prepare: { processor.prepare($0, catalog: $1) },
                reloadWallets: { await wallets.reloadFromStore() },
                currentReviewCatalog: { wallets.reviewCatalog() },
                attemptNativeDecision: { await finalizer.attempt(consent: $0) }
            )
        }
    }


    public let handle: RequestHandle
    public let nativeDeliveryNonce: NativeDeliveryNonce
    public let deliveryStore: any NativeDeliveryStore
    private let environment: Environment
    private var authenticatedAccess: WalletAccessSession?
    private var preparationRevision: UInt64 = 0
    private var currentReview: NativeApprovalReview?

    public var messages: AuthorityMessages { environment.messages }
    public var now: @Sendable () -> Date { environment.now }
    public var uptime: @MainActor @Sendable () -> TimeInterval { environment.uptime }
    public var wait: @MainActor @Sendable (UInt64) async -> Void { environment.wait }
    public var waitForAuthenticationExpiry: @MainActor @Sendable (TimeInterval) async throws -> Void { environment.waitForAuthenticationExpiry }

    init(handle: RequestHandle, nativeDeliveryNonce: NativeDeliveryNonce, store: any NativeDeliveryStore, environment: Environment) {
        self.handle = handle
        self.nativeDeliveryNonce = nativeDeliveryNonce
        deliveryStore = store
        self.environment = environment
    }

    public func acceptAccess(_ access: WalletAccessSession) -> Bool {
        guard access.validateCredentials(for: environment.authorityID) else { return false }
        if authenticatedAccess !== access {
            authenticatedAccess = access
            _ = retireCurrentPreparation()
        }
        return authenticatedAccess === access && permitsPresentation(access)
    }

    public func permitsPresentation(_ access: WalletAccessSession) -> Bool {
        authenticatedAccess === access && access.permitsAuthenticatedPresentation(for: environment.authorityID)
    }

    public func prepareReview(owner: NativeDeliveryOwner, access: WalletAccessSession,
                              until uptimeDeadline: TimeInterval? = nil) async -> Preparation {
        guard !Task.isCancelled, permitsPresentation(access) else { return .unavailable }
        let deadline = min(uptimeDeadline ?? .greatestFiniteMagnitude,
                           environment.uptime() + NativeApprovalTiming.recoveryTimeout)
        guard deadline.isFinite, environment.uptime() < deadline else { return .unavailable }
        let revision = retireCurrentPreparation()
        return await AuthorityMessageContext.$current.withValue(environment.messages) {
            await prepareScoped(owner: owner, access: access, revision: revision, deadline: deadline)
        }
    }

    private func retireCurrentPreparation() -> UInt64 {
        preparationRevision &+= 1
        let revision = preparationRevision
        let previous = currentReview
        currentReview = nil
        previous?.invalidate()
        return revision
    }

    private func isCurrent(_ revision: UInt64, access: WalletAccessSession, deadline: TimeInterval) -> Bool {
        !Task.isCancelled && preparationRevision == revision && environment.uptime() < deadline && permitsPresentation(access)
    }

    isolated deinit { currentReview?.invalidate() }

    private func prepareScoped(owner: NativeDeliveryOwner, access: WalletAccessSession, revision: UInt64, deadline: TimeInterval) async -> Preparation {
        guard isCurrent(revision, access: access, deadline: deadline) else { return .unavailable }
        let loaded = await deliveryStore.load(handle: handle)
        guard isCurrent(revision, access: access, deadline: deadline) else { return .unavailable }
        guard case .found(let initial) = loaded else {
            if case .unavailable = loaded { return .retry }
            return .changed
        }
        guard let binding = currentBinding(initial, owner: owner) else {
            return initial.nativeDeliveryReceipt?.owner.runtimeInstanceIdentifier == owner.runtimeInstanceIdentifier
                ? .unavailable : .changed
        }
        guard environment.now() < binding.request.admissionDeadline else { return .unavailable }
        var preparation = environment.prepare(binding, nil)
        if case .needsCatalog = preparation {
            guard await environment.reloadWallets() else { return .retry }
            guard isCurrent(revision, access: access, deadline: deadline),
                  environment.now() < binding.request.admissionDeadline else { return .unavailable }
            let refreshed = await deliveryStore.load(handle: handle)
            guard isCurrent(revision, access: access, deadline: deadline),
                  environment.now() < binding.request.admissionDeadline else { return .unavailable }
            guard case .found(let current) = refreshed else {
                if case .unavailable = refreshed { return .retry }
                return .changed
            }
            guard let refreshedBinding = currentBinding(current, owner: owner) else {
                return current.nativeDeliveryReceipt?.owner.runtimeInstanceIdentifier == owner.runtimeInstanceIdentifier
                    ? .unavailable : .changed
            }
            guard refreshedBinding == binding else { return .changed }
            guard let catalog = environment.currentReviewCatalog() else { return .retry }
            preparation = environment.prepare(binding, catalog)
        }
        guard isCurrent(revision, access: access, deadline: deadline), environment.now() < binding.request.admissionDeadline else { return .unavailable }
        let receipt = NativeDeliveryReceipt(nativeDeliveryNonce: nativeDeliveryNonce, owner: owner)
        switch preparation {
        case .needsCatalog, .unavailable: return .unavailable
        case .approval(let intent):
            guard intent.binding == binding else { return .unavailable }
            let review = NativeApprovalReview(intent: intent, authorityID: environment.authorityID,
                clock: environment.now, hooks: environment.hooks, access: access, receipt: receipt,
                finalize: { [environment] consent in
                    await AuthorityMessageContext.$current.withValue(environment.messages) {
                        await AuthorityExecutionHooks.$current.withValue(environment.hooks) {
                            await environment.attemptNativeDecision(consent)
                        }
                    }
                })
            guard isCurrent(revision, access: access, deadline: deadline) else { review.invalidate(); return .unavailable }
            currentReview = review
            return .review(review)
        case .immediate(let resolution):
            guard let store = deliveryStore as? any NativeImmediateCompleting else { return .unavailable }
            let handle = handle
            let nonce = nativeDeliveryNonce
            return .immediate(NativeApprovalResponse { [environment] in
                await AuthorityMessageContext.$current.withValue(environment.messages) {
                    await AuthorityExecutionHooks.$current.withValue(environment.hooks) {
                        await store.completeNativeImmediate(handle: handle, nativeDeliveryNonce: nonce,
                            runtimeInstanceIdentifier: owner.runtimeInstanceIdentifier, resolution: resolution)
                    }
                }
            })
        }
    }

    private func currentBinding(_ snapshot: ExtensionBridge.Snapshot, owner: NativeDeliveryOwner) -> ExtensionBridge.RequestBinding? {
        guard snapshot.handle == handle, snapshot.nativeDeliveryNonce == nativeDeliveryNonce,
              case .queued(_, .delivered(let receipt)) = snapshot.state,
              receipt.nativeDeliveryNonce == nativeDeliveryNonce, receipt.owner == owner else { return nil }
        return snapshot.requestBinding
    }
}
