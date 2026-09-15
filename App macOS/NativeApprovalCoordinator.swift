// ∅ 2026 lil org

import Foundation

protocol NativeDeliveryStore: AnyObject {
    func load(
        handle: ExtensionBridge.Handle
    ) async -> ExtensionBridge.SnapshotResult
    func recordNativeDeliveryReceipt(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        owner: ExtensionBridge.NativeDeliveryOwner
    ) async -> ExtensionBridge.StoreMutationResult
    func reject(handle: ExtensionBridge.Handle) async ->
        ExtensionBridge.StoreMutationResult
    func stageNativeDecision(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        decision: DappApprovalDecision,
        approvedAt: Date
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
        case loading(retryDelay: UInt64)
        case reviewing
        case persisting(PersistenceOperation)
        case staged
        case finished
    }

    @MainActor
    private final class PersistenceOperation {
        enum Action {
            case acquireReceipt
            case cancelBeforeAuthentication(receiptOwned: Bool)
            case stage(DappApprovalDecision, approvedAt: Date)
            case respond(ResponseToExtension, preparationDelay: UInt64)
            case reject
        }

        private weak var owner: NativeApprovalCoordinator?
        private let identifier: UUID
        private let handle: ExtensionBridge.Handle
        private let nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce
        private let runtime: ExtensionBridge.NativeDeliveryOwner?
        private let store: NativeDeliveryStore
        private let environment: Environment

        private(set) var action: Action
        var cancellationRequested = false
        private var nextRetryDelay = NativeApprovalCoordinator.initialRetryDelayNanoseconds

        init(
            _ action: Action,
            owner: NativeApprovalCoordinator,
            identifier: UUID
        ) {
            self.action = action
            self.owner = owner
            self.identifier = identifier
            handle = owner.handle
            nativeDeliveryNonce = owner.nativeDeliveryNonce
            runtime = owner.runtime
            store = owner.store
            environment = owner.environment
        }

        private var isCurrent: Bool {
            guard !Task.isCancelled,
                  let owner,
                  owner.foregroundIdentifier == identifier,
                  case .persisting(let current) = owner.lifecycle else {
                return false
            }
            return current === self
        }

        private var hasTimeRemaining: Bool {
            guard let deadline = owner?.terminalDeadline else { return false }
            return environment.now() < deadline
        }

        func prepareAction() {
            switch action {
            case .cancelBeforeAuthentication:
                owner?.terminalDeadline = environment.now().addingTimeInterval(
                    ExtensionBridge.requestTTL
                )
                owner?.stopObservation()
            case .reject:
                owner?.stopObservation()
            case .acquireReceipt, .stage, .respond:
                break
            }
        }

        private func replaceAction(_ action: Action) {
            self.action = action
            cancellationRequested = false
            nextRetryDelay = NativeApprovalCoordinator.initialRetryDelayNanoseconds
            prepareAction()
        }

        func run() async {
            while isCurrent {
                guard hasTimeRemaining else {
                    switch action {
                    case .cancelBeforeAuthentication(receiptOwned: true):
                        owner?.restoreAuthenticationWaiting()
                    case .stage, .respond, .reject:
                        _ = await reconcile(ownershipLost: false, expiring: true)
                    default:
                        owner?.finish()
                    }
                    return
                }

                if cancellationRequested {
                    switch action {
                    case .stage, .respond:
                        guard await reconcile(ownershipLost: false, expiring: false) else {
                            return
                        }
                        continue
                    default:
                        break
                    }
                }

                if case .cancelBeforeAuthentication(let receiptOwned) = action {
                    let loaded = await store.load(handle: handle)
                    guard isCurrent else { return }
                    switch loaded {
                    case .found(let snapshot):
                        guard snapshot.nativeDeliveryNonce == nativeDeliveryNonce,
                              case .queued(let request, let approval) = snapshot.state else {
                            owner?.finish()
                            return
                        }
                        owner?.recordDeadline(from: request)
                        if receiptOwned {
                            guard let runtime,
                                  snapshot.nativeDeliveryReceipt?.matches(
                                    nativeDeliveryNonce: nativeDeliveryNonce,
                                    runtimeInstanceIdentifier: runtime.runtimeInstanceIdentifier
                                  ) == true else {
                                owner?.finish()
                                return
                            }
                            if case .staged = approval {
                                owner?.restoreAuthenticationWaiting()
                                return
                            }
                        } else {
                            guard case .unowned = approval else {
                                owner?.finish()
                                return
                            }
                        }
                    case .missing:
                        owner?.finish()
                        return
                    case .unavailable:
                        await waitForRetry()
                        continue
                    }
                }

                let result: ExtensionBridge.StoreMutationResult
                switch action {
                case .cancelBeforeAuthentication(receiptOwned: false):
                    result = await store.reject(handle: handle)
                default:
                    guard let runtime else {
                        owner?.finish()
                        return
                    }
                    switch action {
                    case .acquireReceipt:
                        result = await store.recordNativeDeliveryReceipt(
                            handle: handle,
                            nativeDeliveryNonce: nativeDeliveryNonce,
                            owner: runtime
                        )
                    case .stage(let decision, let approvedAt):
                        result = await store.stageNativeDecision(
                            handle: handle,
                            nativeDeliveryNonce: nativeDeliveryNonce,
                            runtimeInstanceIdentifier: runtime.runtimeInstanceIdentifier,
                            decision: decision,
                            approvedAt: approvedAt
                        )
                    case .respond(let response, _):
                        result = await store.completeNativeDelivery(
                            handle: handle,
                            nativeDeliveryNonce: nativeDeliveryNonce,
                            runtimeInstanceIdentifier: runtime.runtimeInstanceIdentifier,
                            response: response
                        )
                    case .reject, .cancelBeforeAuthentication:
                        result = await store.rejectNativeDelivery(
                            handle: handle,
                            nativeDeliveryNonce: nativeDeliveryNonce,
                            runtimeInstanceIdentifier: runtime.runtimeInstanceIdentifier
                        )
                    }
                }
                guard isCurrent else { return }

                if case .cancelBeforeAuthentication = action {
                    if result == .persisted {
                        owner?.finish()
                        return
                    }
                    await waitForRetry()
                    continue
                }

                switch result {
                case .persisted:
                    switch action {
                    case .acquireReceipt:
                        if cancellationRequested {
                            replaceAction(.cancelBeforeAuthentication(receiptOwned: true))
                            continue
                        }
                        owner?.restoreAuthenticationWaiting()
                        owner?.onEvent?(.authenticationRequired)
                    case .stage:
                        owner?.enterWaitingState()
                    case .respond, .reject:
                        owner?.finish()
                    case .cancelBeforeAuthentication:
                        break
                    }
                    return
                case .ownershipLost, .retryablePersistenceFailure:
                    if case .acquireReceipt = action {
                        if result == .ownershipLost {
                            owner?.finish()
                            return
                        }
                        await waitForRetry()
                        continue
                    }
                    if case .reject = action, result == .retryablePersistenceFailure {
                        owner?.notifyFailureOnce()
                    }
                    guard await reconcile(
                        ownershipLost: result == .ownershipLost,
                        expiring: false
                    ) else { return }
                }
            }
        }

        private func reconcile(ownershipLost: Bool, expiring: Bool) async -> Bool {
            guard isCurrent else { return false }
            let loaded = await store.load(handle: handle)
            guard isCurrent, let status = owner?.storedStatus(loaded) else {
                return false
            }
            switch status {
            case .staged:
                owner?.enterWaitingState()
            case .responded, .missing:
                owner?.finish()
            case .superseded:
                if case .reject = action { owner?.finish() }
                else { owner?.supersede() }
            case .unavailable:
                if expiring { owner?.finish() }
                else { await waitForRetry() }
            case .pending(_, let receipt):
                guard receipt == .current else {
                    if case .reject = action { owner?.finish() }
                    else { owner?.supersede() }
                    return false
                }
                guard !expiring else {
                    owner?.finish()
                    return false
                }
                if cancellationRequested {
                    replaceAction(.reject)
                    return isCurrent
                }
                if ownershipLost {
                    switch action {
                    case .stage:
                        owner?.notifyFailureOnce()
                        replaceAction(.reject)
                        return isCurrent
                    case .respond(let response, let delay):
                        let nextDelay = owner?.nextDelay(after: delay) ?? delay
                        action = .respond(response, preparationDelay: nextDelay)
                        await wait(after: delay)
                        guard isCurrent else { return false }
                        if cancellationRequested {
                            replaceAction(.reject)
                            return isCurrent
                        }
                        owner?.lifecycle = .loading(retryDelay: nextDelay)
                        if hasTimeRemaining { owner?.prepare() }
                        else { owner?.finish() }
                        return false
                    default:
                        break
                    }
                }
                await waitForRetry()
            }
            return isCurrent
        }

        private func waitForRetry() async {
            guard isCurrent else { return }
            let delay = nextRetryDelay
            nextRetryDelay = owner?.nextDelay(after: delay) ?? delay
            await wait(after: delay)
        }

        private func wait(after delay: UInt64) async {
            guard isCurrent, let deadline = owner?.wakeUptime(after: delay) else {
                return
            }
            let remaining = max(0, deadline - environment.uptime())
            await environment.wait(UInt64(remaining * 1_000_000_000))
        }
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

    struct Environment {
        let now: () -> Date
        let uptime: () -> TimeInterval
        let wait: (UInt64) async -> Void
        let prepareWithoutWallets: @MainActor (SafariRequest) -> DappRequestPreparation?
        let reloadWallets: () -> Bool
        let prepare: @MainActor (SafariRequest) -> DappRequestPreparation
        let finalizeNativeDecision: (ExtensionBridge.Handle) async ->
            NativeApprovalFinalizationResult

        init(
            now: @escaping () -> Date,
            uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            wait: @escaping (UInt64) async -> Void,
            prepareWithoutWallets: @escaping @MainActor (SafariRequest) ->
                DappRequestPreparation? = {
                    DappRequestProcessor().prepareWithoutWallets($0)
                },
            reloadWallets: @escaping () -> Bool = {
                WalletsManager.shared.reloadFromStore()
            },
            prepare: @escaping @MainActor (SafariRequest) -> DappRequestPreparation = {
                DappRequestProcessor().prepare($0)
            },
            finalizeNativeDecision: @escaping (ExtensionBridge.Handle) async ->
                NativeApprovalFinalizationResult = { _ in .pending
            }
        ) {
            self.now = now
            self.uptime = uptime
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

    private nonisolated static let initialRetryDelayNanoseconds: UInt64 = 250_000_000
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
            case .acquireReceipt:
                return .acquiringReceipt(cancelRequested: operation.cancellationRequested)
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
    private var runtime: ExtensionBridge.NativeDeliveryOwner?
    private var foregroundTask: Task<Void, Never>?
    private var foregroundIdentifier: UUID?
    private var observationTask: Task<Void, Never>?
    private var observationIdentifier: UUID?
    private var authenticationExpiryTask: Task<Void, Never>?
    private var authenticationExpiryIdentifier: UUID?
    private var observationDelay = NativeApprovalCoordinator.initialPollingDelayNanoseconds
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
        foregroundTask?.cancel()
        observationTask?.cancel()
        authenticationExpiryTask?.cancel()
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
        nativeDeliveryOwner: ExtensionBridge.NativeDeliveryOwner
    ) {
        guard state == .registered else { return }
        runtime = nativeDeliveryOwner
        lifecycle = .validating
        validate()
    }

    func resumeAfterAuthentication() {
        guard state == .awaitingAuthentication else { return }
        cancelAuthenticationExpiry()
        terminalDeadline = environment.now().addingTimeInterval(
            ExtensionBridge.requestTTL
        )
        lifecycle = .loading(retryDelay: Self.initialRetryDelayNanoseconds)
        prepare()
    }

    func cancelBeforeAuthentication() {
        switch state {
        case .registered, .validating:
            startPersistence(.cancelBeforeAuthentication(receiptOwned: false))
        case .acquiringReceipt:
            requestPersistenceCancellation()
        case .awaitingAuthentication:
            startPersistence(.cancelBeforeAuthentication(receiptOwned: true))
        default:
            break
        }
    }

    private func requestPersistenceCancellation() {
        guard case .persisting(let operation) = lifecycle else { return }
        operation.cancellationRequested = true
    }

    private func startForeground<Value>(
        operation: @escaping @MainActor () async -> Value,
        completion: @escaping (NativeApprovalCoordinator, Value) -> Void
    ) {
        cancelForeground()
        let identifier = UUID()
        foregroundIdentifier = identifier
        foregroundTask = Task { [weak self] in
            guard !Task.isCancelled,
                  self?.foregroundIdentifier == identifier else { return }
            let result = await operation()
            guard !Task.isCancelled,
                  let self, foregroundIdentifier == identifier else { return }
            foregroundIdentifier = nil
            foregroundTask = nil
            completion(self, result)
        }
    }

    private func validate() {
        startForeground(operation: { [store, handle] in
            await store.load(handle: handle)
        }) { coordinator, loaded in
            coordinator.handleValidation(loaded)
        }
    }

    private func handleValidation(_ loaded: ExtensionBridge.SnapshotResult) {
        guard case .found(let snapshot) = loaded,
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
        startPersistence(.acquireReceipt)
    }

    private func prepare() {
        startForeground(operation: { [store, handle] in
            await store.load(handle: handle)
        }) { coordinator, loaded in
            coordinator.handlePreparation(coordinator.storedStatus(loaded))
        }
    }

    private func handlePreparation(_ status: StoredStatus) {
        guard case .loading(let retryDelay) = lifecycle else { return }
        switch status {
        case .pending(let request, let receipt):
            guard environment.now() < terminalDeadline else {
                finish()
                return
            }
            guard receipt == .current else {
                supersede()
                return
            }
            let preparation: DappRequestPreparation
            if let walletIndependent = environment.prepareWithoutWallets(request) {
                preparation = walletIndependent
            } else {
                guard environment.reloadWallets() else {
                    retryPreparation(after: retryDelay)
                    return
                }
                preparation = environment.prepare(request)
            }
            guard environment.now() < terminalDeadline else {
                finish()
                return
            }
            switch preparation {
            case .approval(let action):
                lifecycle = .reviewing
                startObservation()
                onEvent?(.presentation(.approval(request: request, action: action)))
            case .response(let response):
                startPersistence(.respond(response, preparationDelay: retryDelay))
            }
        case .staged:
            enterWaitingState()
        case .responded, .missing:
            finish()
        case .unavailable:
            retryPreparation(after: retryDelay)
        case .superseded:
            supersede()
        }
    }

    private func retryPreparation(after delay: UInt64) {
        guard environment.now() < terminalDeadline else {
            finish()
            return
        }
        lifecycle = .loading(retryDelay: nextDelay(after: delay))
        scheduleForeground(after: delay) { coordinator in
            if coordinator.environment.now() >= coordinator.terminalDeadline {
                coordinator.finish()
            } else {
                coordinator.prepare()
            }
        }
    }

    private func restoreAuthenticationWaiting() {
        cancelForeground()
        stopObservation()
        lifecycle = .awaitingAuthentication
        startAuthenticationExpiry()
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
            startPersistence(.reject)
        case .staging, .responding:
            requestPersistenceCancellation()
        case .staged, .rejecting, .finished:
            break
        }
    }

    private func stage(_ decision: DappApprovalDecision) {
        guard state == .reviewing, runtime != nil else { return }
        startPersistence(.stage(decision, approvedAt: environment.now()))
    }

    private func storedStatus(_ loaded: ExtensionBridge.SnapshotResult) -> StoredStatus {
        switch loaded {
        case .found(let snapshot):
            recordDeadline(from: snapshot.request)
            peer = snapshot.request?.peerMeta ?? PeerMeta(title: snapshot.host)
            guard snapshot.nativeDeliveryNonce == nativeDeliveryNonce else {
                return .superseded
            }
            let request: SafariRequest
            let delivery: ExtensionBridge.NativeDeliveryReceipt?
            switch snapshot.state {
            case .responded:
                return .responded
            case .approving, .queued(_, .staged):
                return .staged
            case .queued(let pendingRequest, .unowned):
                request = pendingRequest
                delivery = nil
            case .queued(let pendingRequest, .delivered(let receipt)):
                request = pendingRequest
                delivery = receipt
            }
            let receipt: ReceiptOwnership
            if let delivery {
                receipt = delivery.nativeDeliveryNonce == nativeDeliveryNonce &&
                    delivery.owner.runtimeInstanceIdentifier == runtime?.runtimeInstanceIdentifier
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
        startPersistence(.reject)
    }

    private func startPersistence(_ action: PersistenceOperation.Action) {
        if case .persisting = lifecycle { return }
        cancelAuthenticationExpiry()
        cancelForeground()
        let identifier = UUID()
        let operation = PersistenceOperation(action, owner: self, identifier: identifier)
        lifecycle = .persisting(operation)
        foregroundIdentifier = identifier
        operation.prepareAction()
        foregroundTask = Task {
            await operation.run()
        }
    }

    private func startObservation() {
        observationDelay = Self.initialPollingDelayNanoseconds
        scheduleObservation()
    }

    private func scheduleObservation() {
        stopObservation()
        guard isLifecycleMonitoredState else { return }
        let identifier = UUID()
        observationIdentifier = identifier
        let deadline = wakeUptime(after: observationDelay)
        let wait = environment.wait
        let uptime = environment.uptime
        let store = store
        let handle = handle
        observationTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let remaining = max(0, deadline - uptime())
            await wait(UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled,
                  self?.observationIdentifier == identifier else { return }
            let loaded = await store.load(handle: handle)
            guard !Task.isCancelled,
                  let self, observationIdentifier == identifier else { return }
            observationIdentifier = nil
            observationTask = nil
            handleObservation(loaded)
        }
    }

    private func handleObservation(_ loaded: ExtensionBridge.SnapshotResult) {
        switch storedStatus(loaded) {
        case .staged:
            finalizeObservedDecision()
            return
        case .responded, .missing, .superseded:
            finish()
        case .pending(_, let receipt):
            if receipt != .current { finish() }
        case .unavailable:
            break
        }
        finishObservation()
    }

    private func finalizeObservedDecision() {
        let identifier = UUID()
        observationIdentifier = identifier
        let finalize = environment.finalizeNativeDecision
        let handle = handle
        observationTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let result = await finalize(handle)
            guard !Task.isCancelled,
                  let self, observationIdentifier == identifier else { return }
            observationIdentifier = nil
            observationTask = nil
            switch result {
            case .responseReady:
                finish()
            case .pending:
                if state != .staged {
                    enterWaitingState()
                    if environment.now() >= terminalDeadline { finish() }
                    return
                }
            case .unavailable:
                notifyFailureOnce()
            }
            finishObservation()
        }
    }

    private func finishObservation() {
        guard isLifecycleMonitoredState else { return }
        guard environment.now() < terminalDeadline else {
            finish()
            return
        }
        observationDelay = nextDelay(after: observationDelay)
        scheduleObservation()
    }

    private var isLifecycleMonitoredState: Bool {
        switch state {
        case .reviewing, .staging, .staged:
            return true
        default:
            return false
        }
    }

    private func enterWaitingState() {
        guard state != .finished else { return }
        let restartObservation = state != .staged
        let shouldNotify = !didEnterWaitingState
        didEnterWaitingState = true
        cancelAuthenticationExpiry()
        cancelForeground()
        lifecycle = .staged
        if restartObservation {
            startObservation()
        }
        if shouldNotify { onEvent?(.presentation(.waiting)) }
    }

    private func cancelForeground() {
        foregroundIdentifier = nil
        foregroundTask?.cancel()
        foregroundTask = nil
    }

    private func stopObservation() {
        observationIdentifier = nil
        observationTask?.cancel()
        observationTask = nil
    }

    private func scheduleForeground(
        after delay: UInt64,
        completion: @escaping (NativeApprovalCoordinator) -> Void
    ) {
        let deadline = wakeUptime(after: delay)
        let wait = environment.wait
        let uptime = environment.uptime
        startForeground(operation: {
            let remaining = max(0, deadline - uptime())
            await wait(UInt64(remaining * 1_000_000_000))
        }) { coordinator, _ in
            completion(coordinator)
        }
    }

    private func wakeUptime(after delay: UInt64) -> TimeInterval {
        environment.uptime() + min(
            max(0, terminalDeadline.timeIntervalSince(environment.now())),
            Double(delay) / 1_000_000_000
        )
    }

    private func cancelAuthenticationExpiry() {
        authenticationExpiryIdentifier = nil
        authenticationExpiryTask?.cancel()
        authenticationExpiryTask = nil
    }

    private func startAuthenticationExpiry() {
        cancelAuthenticationExpiry()
        guard state == .awaitingAuthentication else { return }
        let identifier = UUID()
        authenticationExpiryIdentifier = identifier
        let remaining = max(0, terminalDeadline.timeIntervalSince(environment.now()))
        authenticationExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(remaining))
            } catch {
                return
            }
            guard let self, authenticationExpiryIdentifier == identifier,
                  state == .awaitingAuthentication else { return }
            authenticationExpiryIdentifier = nil
            authenticationExpiryTask = nil
            if environment.now() >= terminalDeadline { finish() }
            else { startAuthenticationExpiry() }
        }
    }

    private func recordDeadline(from request: SafariRequest?) {
        guard let request else { return }
        terminalDeadline = min(terminalDeadline, request.admissionDeadline)
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
        cancelForeground()
        stopObservation()
        cancelAuthenticationExpiry()
        onEvent?(.presentation(presentation))
    }

    private func supersede() {
        finish(.superseded)
    }
}
