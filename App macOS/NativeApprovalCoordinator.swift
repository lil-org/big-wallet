// ∅ 2026 lil org

import Foundation

protocol NativeDeliveryStore: AnyObject {
    func load(
        handle: ExtensionBridge.Handle
    ) async -> ExtensionBridge.SnapshotResult
    func recordNativeDeliveryReceipt(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        owner: ExtensionBridge.NativeDeliveryOwner
    ) async -> ExtensionBridge.StoreMutationResult
    func reject(handle: ExtensionBridge.Handle) async ->
        ExtensionBridge.StoreMutationResult
    func stageNativeDecision(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        decision: DappApprovalDecision
    ) async -> ExtensionBridge.StoreMutationResult
    func completeNativeDelivery(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        response: ResponseToExtension
    ) async -> ExtensionBridge.StoreMutationResult
    func rejectNativeDelivery(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID
    ) async -> ExtensionBridge.StoreMutationResult
}

extension ExtensionBridge: NativeDeliveryStore {}

@MainActor
final class NativeApprovalCoordinator {

    private enum ReceiptOwnership: Equatable {
        case none, current, foreign
    }

    private enum StoredStatus {
        case pending(
            request: SafariRequest,
            receipt: ReceiptOwnership
        )
        case staged
        case responded
        case missing
        case unavailable
        case superseded
    }

    private enum Lifecycle {
        case registered
        case validating
        case awaitingAuthentication
        case loading(PreparationProgress)
        case reviewing
        case persisting(PersistenceOperation)
        case staged
        case finished
    }

    @MainActor
    private final class PreparationProgress {
        var nextRetryDelay = NativeApprovalCoordinator.initialRetryDelayNanoseconds
    }

    @MainActor
    private final class PersistenceOperation {
        enum Action {
            case acquireReceipt(cancelRequested: Bool = false)
            case cancelBeforeAuthentication(receiptOwned: Bool)
            case stage(DappApprovalDecision, cancelRequested: Bool = false)
            case respond(
                ResponseToExtension,
                preparation: PreparationProgress,
                cancelRequested: Bool = false
            )
            case reject
        }

        var action: Action
        var retryCount = 0
        var nextRetryDelay = NativeApprovalCoordinator.initialRetryDelayNanoseconds

        init(_ action: Action) {
            self.action = action
        }

        var cancellationRequested: Bool {
            switch action {
            case .acquireReceipt(let requested), .stage(_, let requested),
                 .respond(_, _, let requested):
                return requested
            case .cancelBeforeAuthentication, .reject:
                return false
            }
        }

        func requestCancellation() {
            switch action {
            case .acquireReceipt:
                action = .acquireReceipt(cancelRequested: true)
            case .stage(let decision, _):
                action = .stage(decision, cancelRequested: true)
            case .respond(let response, let preparation, _) where retryCount < 3:
                action = .respond(response, preparation: preparation, cancelRequested: true)
            case .respond, .cancelBeforeAuthentication, .reject:
                break
            }
        }
    }

    private enum PersistenceStep {
        case retry
        case stop
        case replace(PersistenceOperation.Action)
        case prepareAgain
    }

    enum State: Equatable {
        case registered
        case validating
        case acquiringReceipt(cancelRequested: Bool)
        case awaitingAuthentication
        case cancelingBeforeAuthentication(receiptOwned: Bool)
        case loading
        case reviewing
        case staging
        case staged
        case responding
        case rejecting
        case finished
    }

    enum Presentation {
        case approval(request: SafariRequest, action: DappRequestAction)
        case waiting
        case rejecting
        case finished
        case superseded
    }

    enum Event {
        case authenticationRequired
        case presentation(Presentation)
    }

    struct Order: Equatable {
        let createdAt: Date
        let sequence: Int
    }

    private struct Runtime {
        let instanceIdentifier: UUID
        let owner: ExtensionBridge.NativeDeliveryOwner
    }

    struct Environment {
        let now: () -> Date
        let wait: (UInt64) async -> Void
        let prepareWithoutWallets: (SafariRequest) -> DappRequestPreparation?
        let reloadWallets: () -> Bool
        let prepare: (SafariRequest) -> DappRequestPreparation
        let finalizeNativeDecision: (ExtensionBridge.Handle) async ->
            NativeApprovalFinalizationResult

        init(
            now: @escaping () -> Date,
            wait: @escaping (UInt64) async -> Void,
            prepareWithoutWallets: @escaping (SafariRequest) ->
                DappRequestPreparation? = {
                    DappRequestProcessor.prepareWithoutWallets($0)
                },
            reloadWallets: @escaping () -> Bool = {
                WalletsManager.shared.reloadFromStore()
            },
            prepare: @escaping (SafariRequest) -> DappRequestPreparation = {
                DappRequestProcessor.prepare($0)
            },
            finalizeNativeDecision: @escaping (ExtensionBridge.Handle) async ->
                NativeApprovalFinalizationResult = { _ in .pending
            }
        ) {
            self.now = now
            self.wait = wait
            self.prepareWithoutWallets = prepareWithoutWallets
            self.reloadWallets = reloadWallets
            self.prepare = prepare
            self.finalizeNativeDecision = finalizeNativeDecision
        }

        static let live = Environment(
            now: Date.init,
            wait: { nanoseconds in
                try? await Task.sleep(nanoseconds: nanoseconds)
            },
            finalizeNativeDecision: { handle in
                await NativeApprovalFinalizer.shared.finalize(handle: handle)
            }
        )
    }

    private static let initialRetryDelayNanoseconds: UInt64 = 250_000_000
    private static let initialPollingDelayNanoseconds: UInt64 = 1_000_000_000
    private static let maximumDelayNanoseconds: UInt64 = 5_000_000_000

    let handle: ExtensionBridge.Handle
    var state: State {
        switch lifecycle {
        case .registered: return .registered
        case .validating: return .validating
        case .awaitingAuthentication: return .awaitingAuthentication
        case .loading: return .loading
        case .reviewing: return .reviewing
        case .staged: return .staged
        case .finished: return .finished
        case .persisting(let operation):
            switch operation.action {
            case .acquireReceipt(let cancelRequested):
                return .acquiringReceipt(cancelRequested: cancelRequested)
            case .cancelBeforeAuthentication(let receiptOwned):
                return .cancelingBeforeAuthentication(receiptOwned: receiptOwned)
            case .stage: return .staging
            case .respond: return .responding
            case .reject: return .rejecting
            }
        }
    }
    let nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce
    private(set) var peer: PeerMeta?
    private(set) var order: Order?
    var onEvent: ((Event) -> Void)?

    private let store: NativeDeliveryStore
    private let environment: Environment
    private var lifecycle = Lifecycle.registered
    private var runtime: Runtime?
    private var bootstrapTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var terminalDeadline: Date
    private var didNotifyFailure = false
    private var didEnterWaitingState = false

    init(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        store: NativeDeliveryStore = ExtensionBridge.shared,
        environment: Environment = .live
    ) {
        self.handle = handle
        self.nativeDeliveryNonce = nativeDeliveryNonce
        self.store = store
        self.environment = environment
        terminalDeadline = environment.now().addingTimeInterval(
            ExtensionBridge.requestTTL
        )
    }

    deinit {
        bootstrapTask?.cancel()
        monitorTask?.cancel()
        persistenceTask?.cancel()
    }

    var countsTowardUnverifiedLimit: Bool {
        switch state {
        case .registered, .validating, .acquiringReceipt,
             .cancelingBeforeAuthentication(receiptOwned: false):
            return true
        default:
            return false
        }
    }

    func start(
        runtimeInstanceIdentifier: UUID,
        nativeDeliveryOwner: ExtensionBridge.NativeDeliveryOwner
    ) {
        guard state == .registered else { return }
        runtime = Runtime(
            instanceIdentifier: runtimeInstanceIdentifier,
            owner: nativeDeliveryOwner
        )
        lifecycle = .validating
        bootstrapTask = Task { [weak self] in
            await self?.validateAndAcquireReceipt()
        }
    }

    private func validateAndAcquireReceipt() async {
        let result = await store.load(handle: handle)
        guard state == .validating else { return }
        guard case .found(let snapshot) = result,
              snapshot.nativeDeliveryNonce == nativeDeliveryNonce,
              snapshot.phase != .responded,
              runtime != nil else {
            finish()
            return
        }
        order = Order(createdAt: snapshot.createdAt, sequence: snapshot.sequence)
        terminalDeadline = environment.now().addingTimeInterval(
            ExtensionBridge.requestTTL
        )
        recordDeadline(from: snapshot.request)
        startPersistence(.acquireReceipt())
    }

    func resumeAfterAuthentication() {
        guard state == .awaitingAuthentication else { return }
        terminalDeadline = environment.now().addingTimeInterval(
            ExtensionBridge.requestTTL
        )
        lifecycle = .loading(PreparationProgress())
        bootstrapTask = Task { [weak self] in
            await self?.preparePresentation()
        }
    }

    func cancelBeforeAuthentication() {
        switch state {
        case .registered, .validating:
            bootstrapTask?.cancel()
            bootstrapTask = nil
            beginPreauthenticationCancellation(receiptOwned: false)
        case .acquiringReceipt:
            if case .persisting(let operation) = lifecycle {
                operation.requestCancellation()
            }
        case .awaitingAuthentication:
            beginPreauthenticationCancellation(receiptOwned: true)
        default:
            break
        }
    }

    private func beginPreauthenticationCancellation(receiptOwned: Bool) {
        startPersistence(.cancelBeforeAuthentication(receiptOwned: receiptOwned))
    }

    private func cancelBeforeAuthenticationAttempt(
        _ operation: PersistenceOperation,
        receiptOwned: Bool
    ) async -> PersistenceStep {
        let loaded = await store.load(handle: handle)
        guard isCurrent(operation) else { return .stop }
        switch loaded {
        case .found(let snapshot):
            guard snapshot.nativeDeliveryNonce == nativeDeliveryNonce,
                  snapshot.phase != .responded else {
                finish()
                return .stop
            }
            recordDeadline(from: snapshot.request)
            let result: ExtensionBridge.StoreMutationResult
            if receiptOwned {
                guard let runtime,
                      snapshot.nativeDeliveryReceipt?.matches(
                          nativeDeliveryNonce: nativeDeliveryNonce,
                          runtimeInstanceIdentifier: runtime.instanceIdentifier
                      ) == true,
                      snapshot.phase == .queued else {
                    finish()
                    return .stop
                }
                if snapshot.nativeDecisionStaged {
                    restoreAuthenticationWaiting()
                    return .stop
                }
                result = await store.rejectNativeDelivery(
                    handle: handle,
                    nativeDeliveryNonce: nativeDeliveryNonce,
                    runtimeInstanceIdentifier: runtime.instanceIdentifier
                )
            } else {
                guard snapshot.nativeDeliveryReceipt == nil,
                      !snapshot.nativeDecisionStaged,
                      snapshot.phase == .queued else {
                    finish()
                    return .stop
                }
                result = await store.reject(handle: handle)
            }
            guard isCurrent(operation) else { return .stop }
            if result == .persisted {
                finish()
                return .stop
            }
        case .missing:
            finish()
            return .stop
        case .unavailable:
            break
        }
        return .retry
    }

    private func restoreAuthenticationWaiting() {
        persistenceTask = nil
        lifecycle = .awaitingAuthentication
    }

    private func preparePresentation() async {
        guard case .loading(let progress) = lifecycle else { return }

        while isCurrent(progress) {
            guard environment.now() < terminalDeadline else {
                finish()
                return
            }
            if await preparePresentationAttempt(progress: progress) { return }
            guard isCurrent(progress) else { return }
            guard environment.now() < terminalDeadline else {
                finish()
                return
            }
            await waitBeforeDeadline(progress.nextRetryDelay)
            guard isCurrent(progress) else { return }
            guard environment.now() < terminalDeadline else {
                finish()
                return
            }
            progress.nextRetryDelay = nextDelay(after: progress.nextRetryDelay)
        }
    }

    private func preparePresentationAttempt(progress: PreparationProgress) async -> Bool {
        let status = await storedStatus()
        guard isCurrent(progress) else { return false }
        switch status {
        case .pending(let request, let receipt):
            guard environment.now() < terminalDeadline else {
                finish()
                return true
            }
            guard receipt == .current else {
                supersede()
                return true
            }
            let preparation: DappRequestPreparation
            if let walletIndependent = environment.prepareWithoutWallets(
                request
            ) {
                preparation = walletIndependent
            } else {
                guard environment.reloadWallets() else { return false }
                preparation = environment.prepare(request)
            }
            guard environment.now() < terminalDeadline else {
                finish()
                return true
            }
            switch preparation {
            case .approval(let action):
                lifecycle = .reviewing
                startLifecycleMonitor()
                bootstrapTask = nil
                onEvent?(.presentation(.approval(request: request, action: action)))
                return true
            case .response(let response):
                startPersistence(.respond(response, preparation: progress))
                return true
            }
        case .staged:
            enterWaitingState(notify: true)
            return true
        case .responded, .missing:
            finish()
            return true
        case .unavailable:
            return false
        case .superseded:
            supersede()
            return true
        }
    }

    func approveAccounts(
        _ accounts: [SpecificWalletAccount],
        ethereumNetwork: EthereumNetwork?
    ) {
        let identities = accounts.map {
            DappApprovalDecision.AccountIdentity(
                walletID: $0.walletId,
                address: $0.account.address,
                provider: $0.account.coin.correspondingInpageProvider,
                derivationPath: $0.account.derivationPath
            )
        }
        stage(.accountSelection(.init(
            accounts: identities,
            ethereumChainID: ethereumNetwork?.chainIdHexString
        )))
    }

    func approveMessage(solanaCluster: Solana.Cluster?) {
        stage(.message(.init(solanaCluster: solanaCluster)))
    }

    func approveTransaction(
        _ transaction: Transaction,
        reviewedNetwork: ResolvedEthereumNetwork
    ) {
        guard let execution = DappApprovalDecision.TransactionExecution(
            transaction,
            reviewedNetwork: reviewedNetwork
        ) else {
            failAndReject()
            return
        }
        stage(.transaction(execution))
    }

    func approveAddEthereumChain() {
        stage(.addEthereumChain)
    }

    func reject() {
        switch state {
        case .registered, .validating, .acquiringReceipt,
             .awaitingAuthentication, .cancelingBeforeAuthentication:
            cancelBeforeAuthentication()
        case .loading, .reviewing:
            takeRejectionOwnership()
        case .staging, .responding:
            if case .persisting(let operation) = lifecycle {
                operation.requestCancellation()
            }
        case .staged, .rejecting, .finished:
            break
        }
    }

    private func stage(_ decision: DappApprovalDecision) {
        guard state == .reviewing, runtime != nil else { return }
        startPersistence(.stage(decision))
    }

    private func storedStatus() async -> StoredStatus {
        switch await store.load(handle: handle) {
        case .found(let snapshot):
            recordDeadline(from: snapshot.request)
            peer = snapshot.request?.peerMeta ?? PeerMeta(title: snapshot.host)
            guard snapshot.nativeDeliveryNonce == nativeDeliveryNonce else {
                return .superseded
            }
            if snapshot.phase == .responded { return .responded }
            if snapshot.nativeDecisionStaged || snapshot.phase == .approving {
                return .staged
            }
            guard let request = snapshot.request else { return .responded }
            let receipt: ReceiptOwnership
            if let owner = snapshot.nativeDeliveryReceipt {
                receipt = owner.nativeDeliveryNonce == nativeDeliveryNonce &&
                    owner.runtimeInstanceIdentifier == runtime?.instanceIdentifier
                    ? .current : .foreign
            } else {
                receipt = .none
            }
            return .pending(request: request, receipt: receipt)
        case .missing:
            return .missing
        case .unavailable:
            return .unavailable
        }
    }

    private func failAndReject() {
        guard state != .rejecting, state != .responding, state != .finished else {
            return
        }
        notifyFailureOnce()
        takeRejectionOwnership()
    }

    private func takeRejectionOwnership() {
        startPersistence(.reject)
    }

    private func startPersistence(_ action: PersistenceOperation.Action) {
        if case .persisting = lifecycle { return }
        let operation = installPersistence(action)
        persistenceTask = Task { [weak self] in
            await self?.runPersistence(operation)
        }
    }

    private func installPersistence(
        _ action: PersistenceOperation.Action
    ) -> PersistenceOperation {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        let operation = PersistenceOperation(action)
        lifecycle = .persisting(operation)
        switch action {
        case .cancelBeforeAuthentication:
            terminalDeadline = environment.now().addingTimeInterval(
                ExtensionBridge.requestTTL
            )
        case .reject:
            stopLifecycleMonitor()
        case .acquireReceipt, .stage, .respond:
            break
        }
        return operation
    }

    private func isCurrent(_ operation: PersistenceOperation) -> Bool {
        guard !Task.isCancelled,
              case .persisting(let current) = lifecycle else { return false }
        return current === operation
    }

    private func isCurrent(_ progress: PreparationProgress) -> Bool {
        guard !Task.isCancelled,
              case .loading(let current) = lifecycle else { return false }
        return current === progress
    }

    private func runPersistence(_ initialOperation: PersistenceOperation) async {
        var operation = initialOperation
        while isCurrent(operation) {
            guard environment.now() < terminalDeadline else {
                await expirePersistence(operation)
                return
            }
            let step: PersistenceStep
            if operation.cancellationRequested,
               state == .staging || state == .responding {
                step = .replace(.reject)
            } else {
                step = await persistenceAttempt(operation)
            }
            guard isCurrent(operation) else { return }
            switch step {
            case .stop:
                return
            case .replace(let action):
                operation = installPersistence(action)
            case .prepareAgain:
                guard case .respond(_, let progress, _) = operation.action else {
                    return
                }
                await waitBeforeDeadline(progress.nextRetryDelay)
                guard isCurrent(operation) else { return }
                if operation.cancellationRequested {
                    operation = installPersistence(.reject)
                    continue
                }
                progress.nextRetryDelay = nextDelay(after: progress.nextRetryDelay)
                persistenceTask = nil
                lifecycle = .loading(progress)
                bootstrapTask = Task { [weak self] in
                    await self?.preparePresentation()
                }
                return
            case .retry:
                operation.retryCount += 1
                if case .stage = operation.action, operation.retryCount >= 3 {
                    notifyFailureOnce()
                    operation = installPersistence(.reject)
                    continue
                }
                if case .respond = operation.action, operation.retryCount == 3 {
                    notifyFailureOnce()
                }
                await waitBeforeDeadline(operation.nextRetryDelay)
                guard isCurrent(operation) else { return }
                operation.nextRetryDelay = nextDelay(after: operation.nextRetryDelay)
            }
        }
    }

    private func persistenceAttempt(
        _ operation: PersistenceOperation
    ) async -> PersistenceStep {
        if case .cancelBeforeAuthentication(let receiptOwned) = operation.action {
            return await cancelBeforeAuthenticationAttempt(
                operation,
                receiptOwned: receiptOwned
            )
        }
        guard let runtime else {
            finish()
            return .stop
        }
        let result: ExtensionBridge.StoreMutationResult
        switch operation.action {
        case .acquireReceipt:
            result = await store.recordNativeDeliveryReceipt(
                handle: handle,
                nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtime.instanceIdentifier,
                owner: runtime.owner
            )
        case .stage(let decision, _):
            result = await store.stageNativeDecision(
                handle: handle,
                nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtime.instanceIdentifier,
                decision: decision
            )
        case .respond(let response, _, _):
            result = await store.completeNativeDelivery(
                handle: handle,
                nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtime.instanceIdentifier,
                response: response
            )
        case .reject:
            result = await store.rejectNativeDelivery(
                handle: handle,
                nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtime.instanceIdentifier
            )
        case .cancelBeforeAuthentication:
            return .stop
        }
        guard isCurrent(operation) else { return .stop }
        switch result {
        case .persisted:
            switch operation.action {
            case .acquireReceipt(let cancelRequested):
                if cancelRequested {
                    return .replace(.cancelBeforeAuthentication(receiptOwned: true))
                }
                persistenceTask = nil
                lifecycle = .awaitingAuthentication
                onEvent?(.authenticationRequired)
            case .stage:
                enterWaitingState(notify: true)
            case .respond, .reject:
                finish()
            case .cancelBeforeAuthentication:
                break
            }
            return .stop
        case .ownershipLost:
            if case .acquireReceipt = operation.action {
                finish()
                return .stop
            }
            return await reconcilePersistence(operation)
        case .retryablePersistenceFailure:
            switch operation.action {
            case .stage:
                return operation.cancellationRequested ? .replace(.reject) : .retry
            case .respond where operation.cancellationRequested:
                return .replace(.reject)
            case .reject:
                notifyFailureOnce()
                return await reconcilePersistence(operation)
            case .respond where operation.retryCount >= 3:
                notifyFailureOnce()
                return await reconcilePersistence(operation)
            default:
                return .retry
            }
        }
    }

    private func reconcilePersistence(
        _ operation: PersistenceOperation
    ) async -> PersistenceStep {
        let status = await storedStatus()
        guard isCurrent(operation) else { return .stop }
        switch status {
        case .staged:
            let notify: Bool
            if case .respond = operation.action {
                notify = operation.retryCount < 3
            } else {
                notify = true
            }
            enterWaitingState(notify: notify)
        case .responded, .missing:
            finish()
        case .superseded:
            switch operation.action {
            case .stage:
                notifyFailureOnce()
                return .replace(.reject)
            case .respond where operation.retryCount < 3:
                supersede()
            default:
                finish()
            }
        case .pending, .unavailable:
            switch operation.action {
            case .stage:
                notifyFailureOnce()
                return .replace(.reject)
            case .respond where operation.retryCount < 3:
                return operation.cancellationRequested ? .replace(.reject) : .prepareAgain
            default:
                switch status {
                case .pending(_, .current):
                    return .retry
                case .pending:
                    finish()
                case .unavailable:
                    notifyFailureOnce()
                    return .retry
                default:
                    break
                }
            }
        }
        return .stop
    }

    private func expirePersistence(
        _ operation: PersistenceOperation
    ) async {
        switch operation.action {
        case .cancelBeforeAuthentication(receiptOwned: true):
            restoreAuthenticationWaiting()
        case .respond where operation.retryCount < 3:
            finish()
        case .reject, .respond:
            _ = await reconcilePersistence(operation)
            if isCurrent(operation) { finish() }
        default:
            finish()
        }
    }

    private func startLifecycleMonitor() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            var pollingDelay = Self.initialPollingDelayNanoseconds
            while !Task.isCancelled, isLifecycleMonitoredState {
                await waitBeforeDeadline(pollingDelay)
                guard !Task.isCancelled, isLifecycleMonitoredState else {
                    return
                }
                let status = await storedStatus()
                guard !Task.isCancelled, isLifecycleMonitoredState else { return }
                switch status {
                case .staged:
                    let result = await environment.finalizeNativeDecision(handle)
                    guard !Task.isCancelled, isLifecycleMonitoredState else { return }
                    switch result {
                    case .responseReady:
                        finish()
                    case .pending:
                        enterWaitingState(notify: true)
                    case .unavailable:
                        notifyFailureOnce()
                    }
                case .responded, .missing, .superseded:
                    finish()
                case .pending(_, let receipt):
                    if receipt != .current { finish() }
                case .unavailable:
                    break
                }
                if isLifecycleMonitoredState,
                   environment.now() >= terminalDeadline {
                    finish()
                }
                pollingDelay = nextDelay(after: pollingDelay)
            }
        }
    }

    private var isLifecycleMonitoredState: Bool {
        switch state {
        case .reviewing, .staging, .staged:
            return true
        default:
            return false
        }
    }

    private func enterWaitingState(notify: Bool) {
        guard state != .finished else { return }
        let shouldRestartLifecycleMonitor = state != .staged
        let shouldNotify = notify && !didEnterWaitingState
        didEnterWaitingState = true
        bootstrapTask?.cancel()
        bootstrapTask = nil
        persistenceTask?.cancel()
        persistenceTask = nil
        lifecycle = .staged
        if shouldRestartLifecycleMonitor {
            stopLifecycleMonitor()
        }
        if shouldNotify {
            onEvent?(.presentation(.waiting))
        }
        startLifecycleMonitor()
    }

    private func stopLifecycleMonitor() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func recordDeadline(from request: SafariRequest?) {
        guard let request else { return }
        terminalDeadline = min(terminalDeadline, request.admissionDeadline)
    }

    private func waitBeforeDeadline(_ nanoseconds: UInt64) async {
        let remaining = max(
            0,
            terminalDeadline.timeIntervalSince(environment.now())
        )
        let remainingNanoseconds = UInt64(
            min(remaining * 1_000_000_000, Double(UInt64.max))
        )
        await environment.wait(min(nanoseconds, remainingNanoseconds))
    }

    private func nextDelay(after delay: UInt64) -> UInt64 {
        min(delay.multipliedReportingOverflow(by: 2).partialValue,
            Self.maximumDelayNanoseconds)
    }

    private func notifyFailureOnce() {
        guard !didNotifyFailure else { return }
        didNotifyFailure = true
        onEvent?(.presentation(.rejecting))
    }

    private func finish(_ presentation: Presentation = .finished) {
        guard state != .finished else { return }
        lifecycle = .finished
        bootstrapTask?.cancel()
        bootstrapTask = nil
        stopLifecycleMonitor()
        persistenceTask?.cancel()
        persistenceTask = nil
        onEvent?(.presentation(presentation))
    }

    private func supersede() {
        finish(.superseded)
    }
}
