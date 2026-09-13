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

    private struct PersistenceOperation {
        enum Action {
            case acquireReceipt
            case cancelBeforeAuthentication(receiptOwned: Bool)
            case stage(DappApprovalDecision, approvedAt: Date)
            case respond(ResponseToExtension, preparationDelay: UInt64)
            case reject
        }

        var action: Action
        var cancellationRequested = false
        var nextRetryDelay = NativeApprovalCoordinator.initialRetryDelayNanoseconds

        init(_ action: Action) {
            self.action = action
        }
    }

    private enum ForegroundEffect {
        case validate
        case prepare
        case cancelBeforeAuthentication(receiptOwned: Bool)
        case persist(Mutation)
        case reconcile(ownershipLost: Bool, expiring: Bool)
    }

    private enum Mutation {
        case acquireReceipt
        case stage(DappApprovalDecision, approvedAt: Date)
        case respond(ResponseToExtension)
        case reject(receiptOwned: Bool)
    }

    private enum ForegroundResult {
        case loaded(ExtensionBridge.SnapshotResult)
        case persisted(ExtensionBridge.StoreMutationResult)
    }

    private enum ForegroundWake {
        case prepare
        case persist
        case prepareAgain
    }

    private enum WakePurpose: Equatable {
        case foreground
        case observation
        case authenticationExpiry
    }

    private struct ScheduledWake: Equatable {
        let purpose: WakePurpose
        let uptime: TimeInterval
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
    private var runtime: Runtime?
    private var foregroundTask: Task<Void, Never>?
    private var foregroundIdentifier: UUID?
    private var observationTask: Task<Void, Never>?
    private var observationIdentifier: UUID?
    private var wakeTask: Task<Void, Never>?
    private var wakeIdentifier: UUID?
    private var scheduledWake: ScheduledWake?
    private var foregroundWake: (action: ForegroundWake, uptime: TimeInterval)?
    private var observationUptime: TimeInterval?
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
        wakeTask?.cancel()
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
        startForeground(.validate)
    }

    func resumeAfterAuthentication() {
        guard state == .awaitingAuthentication else { return }
        terminalDeadline = environment.now().addingTimeInterval(
            ExtensionBridge.requestTTL
        )
        lifecycle = .loading(retryDelay: Self.initialRetryDelayNanoseconds)
        startForeground(.prepare)
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
        guard case .persisting(var operation) = lifecycle else { return }
        operation.cancellationRequested = true
        lifecycle = .persisting(operation)
    }

    private func startForeground(_ effect: ForegroundEffect) {
        cancelForeground()
        let identifier = UUID()
        foregroundIdentifier = identifier
        let store = store
        let handle = handle
        let nonce = nativeDeliveryNonce
        let runtime = runtime
        foregroundTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let result: ForegroundResult
            switch effect {
            case .validate, .prepare, .cancelBeforeAuthentication, .reconcile:
                result = .loaded(await store.load(handle: handle))
            case .persist(let mutation):
                let persisted: ExtensionBridge.StoreMutationResult
                switch mutation {
                case .acquireReceipt:
                    guard let runtime else { return }
                    persisted = await store.recordNativeDeliveryReceipt(
                        handle: handle,
                        nativeDeliveryNonce: nonce,
                        runtimeInstanceIdentifier: runtime.instanceIdentifier,
                        owner: runtime.owner
                    )
                case .stage(let decision, let approvedAt):
                    guard let runtime else { return }
                    persisted = await store.stageNativeDecision(
                        handle: handle,
                        nativeDeliveryNonce: nonce,
                        runtimeInstanceIdentifier: runtime.instanceIdentifier,
                        decision: decision,
                        approvedAt: approvedAt
                    )
                case .respond(let response):
                    guard let runtime else { return }
                    persisted = await store.completeNativeDelivery(
                        handle: handle,
                        nativeDeliveryNonce: nonce,
                        runtimeInstanceIdentifier: runtime.instanceIdentifier,
                        response: response
                    )
                case .reject(let receiptOwned):
                    if receiptOwned {
                        guard let runtime else { return }
                        persisted = await store.rejectNativeDelivery(
                            handle: handle,
                            nativeDeliveryNonce: nonce,
                            runtimeInstanceIdentifier: runtime.instanceIdentifier
                        )
                    } else {
                        persisted = await store.reject(handle: handle)
                    }
                }
                result = .persisted(persisted)
            }
            guard let self, foregroundIdentifier == identifier else { return }
            foregroundIdentifier = nil
            foregroundTask = nil
            handleForeground(result, for: effect)
        }
        scheduleNextWake()
    }

    private func handleForeground(
        _ result: ForegroundResult,
        for effect: ForegroundEffect
    ) {
        switch (effect, result) {
        case (.validate, .loaded(let loaded)):
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
        case (.prepare, .loaded(let loaded)):
            handlePreparation(storedStatus(loaded))
        case (.cancelBeforeAuthentication(let receiptOwned), .loaded(let loaded)):
            handlePreauthenticationCancellation(loaded, receiptOwned: receiptOwned)
        case (.persist, .persisted(let persisted)):
            handlePersistence(persisted)
        case (.reconcile(let ownershipLost, let expiring), .loaded(let loaded)):
            handleReconciliation(
                storedStatus(loaded),
                ownershipLost: ownershipLost,
                expiring: expiring
            )
        default:
            preconditionFailure()
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
        scheduleForeground(.prepare, after: delay)
    }

    private func handlePreauthenticationCancellation(
        _ loaded: ExtensionBridge.SnapshotResult,
        receiptOwned: Bool
    ) {
        switch loaded {
        case .found(let snapshot):
            guard snapshot.nativeDeliveryNonce == nativeDeliveryNonce,
                  snapshot.phase != .responded else {
                finish()
                return
            }
            recordDeadline(from: snapshot.request)
            if receiptOwned {
                guard let runtime,
                      snapshot.nativeDeliveryReceipt?.matches(
                          nativeDeliveryNonce: nativeDeliveryNonce,
                          runtimeInstanceIdentifier: runtime.instanceIdentifier
                      ) == true,
                      snapshot.phase == .queued else {
                    finish()
                    return
                }
                if snapshot.nativeDecisionStaged {
                    restoreAuthenticationWaiting()
                    return
                }
            } else {
                guard snapshot.nativeDeliveryReceipt == nil,
                      !snapshot.nativeDecisionStaged,
                      snapshot.phase == .queued else {
                    finish()
                    return
                }
            }
            startForeground(.persist(.reject(receiptOwned: receiptOwned)))
        case .missing:
            finish()
        case .unavailable:
            retryPersistence()
        }
    }

    private func restoreAuthenticationWaiting() {
        cancelForeground()
        stopObservation()
        lifecycle = .awaitingAuthentication
        scheduleNextWake()
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
        startPersistence(.reject)
    }

    private func startPersistence(_ action: PersistenceOperation.Action) {
        if case .persisting = lifecycle { return }
        replacePersistence(action)
    }

    private func replacePersistence(_ action: PersistenceOperation.Action) {
        cancelForeground()
        lifecycle = .persisting(PersistenceOperation(action))
        switch action {
        case .cancelBeforeAuthentication:
            terminalDeadline = environment.now().addingTimeInterval(
                ExtensionBridge.requestTTL
            )
            stopObservation()
        case .reject:
            stopObservation()
        case .acquireReceipt, .stage, .respond:
            break
        }
        performPersistence()
    }

    private func performPersistence() {
        guard case .persisting(let operation) = lifecycle else { return }
        guard environment.now() < terminalDeadline else {
            expirePersistence()
            return
        }
        if operation.cancellationRequested,
           state == .staging || state == .responding {
            startForeground(.reconcile(ownershipLost: false, expiring: false))
            return
        }
        if case .cancelBeforeAuthentication(let receiptOwned) = operation.action {
            startForeground(.cancelBeforeAuthentication(receiptOwned: receiptOwned))
            return
        }
        guard runtime != nil else {
            finish()
            return
        }
        let mutation: Mutation
        switch operation.action {
        case .acquireReceipt:
            mutation = .acquireReceipt
        case .stage(let decision, let approvedAt):
            mutation = .stage(decision, approvedAt: approvedAt)
        case .respond(let response, _):
            mutation = .respond(response)
        case .reject:
            mutation = .reject(receiptOwned: true)
        case .cancelBeforeAuthentication:
            return
        }
        startForeground(.persist(mutation))
    }

    private func handlePersistence(_ result: ExtensionBridge.StoreMutationResult) {
        guard case .persisting(let operation) = lifecycle else { return }
        if case .cancelBeforeAuthentication = operation.action {
            if result == .persisted { finish() }
            else { retryPersistence() }
            return
        }
        switch result {
        case .persisted:
            switch operation.action {
            case .acquireReceipt:
                if operation.cancellationRequested {
                    replacePersistence(.cancelBeforeAuthentication(receiptOwned: true))
                } else {
                    restoreAuthenticationWaiting()
                    onEvent?(.authenticationRequired)
                }
            case .stage:
                enterWaitingState()
            case .respond, .reject:
                finish()
            case .cancelBeforeAuthentication:
                break
            }
        case .ownershipLost, .retryablePersistenceFailure:
            if case .acquireReceipt = operation.action {
                if result == .ownershipLost { finish() }
                else { retryPersistence() }
                return
            }
            if case .reject = operation.action, result == .retryablePersistenceFailure {
                notifyFailureOnce()
            }
            startForeground(.reconcile(
                ownershipLost: result == .ownershipLost,
                expiring: false
            ))
        }
    }

    private func handleReconciliation(
        _ status: StoredStatus,
        ownershipLost: Bool,
        expiring: Bool
    ) {
        guard case .persisting(var operation) = lifecycle else { return }
        switch status {
        case .staged:
            enterWaitingState()
        case .responded, .missing:
            finish()
        case .superseded:
            if case .reject = operation.action { finish() }
            else { supersede() }
        case .unavailable:
            if expiring { finish() }
            else { retryPersistence() }
        case .pending(_, let receipt):
            guard receipt == .current else {
                if case .reject = operation.action { finish() }
                else { supersede() }
                return
            }
            guard !expiring else {
                finish()
                return
            }
            if operation.cancellationRequested {
                replacePersistence(.reject)
                return
            }
            if ownershipLost {
                switch operation.action {
                case .stage:
                    notifyFailureOnce()
                    replacePersistence(.reject)
                    return
                case .respond(let response, let delay):
                    operation.action = .respond(
                        response,
                        preparationDelay: nextDelay(after: delay)
                    )
                    lifecycle = .persisting(operation)
                    scheduleForeground(.prepareAgain, after: delay)
                    return
                default:
                    break
                }
            }
            retryPersistence()
        }
    }

    private func retryPersistence() {
        guard case .persisting(var operation) = lifecycle else { return }
        let delay = operation.nextRetryDelay
        operation.nextRetryDelay = nextDelay(after: delay)
        lifecycle = .persisting(operation)
        scheduleForeground(.persist, after: delay)
    }

    private func expirePersistence() {
        guard case .persisting(let operation) = lifecycle else { return }
        switch operation.action {
        case .cancelBeforeAuthentication(receiptOwned: true):
            restoreAuthenticationWaiting()
        case .stage, .respond, .reject:
            startForeground(.reconcile(ownershipLost: false, expiring: true))
        default:
            finish()
        }
    }

    private func startObservation() {
        observationDelay = Self.initialPollingDelayNanoseconds
        observationUptime = wakeUptime(after: observationDelay)
        scheduleNextWake()
    }

    private func observe() {
        guard isLifecycleMonitoredState, observationIdentifier == nil else { return }
        let identifier = UUID()
        observationIdentifier = identifier
        let store = store
        let handle = handle
        observationTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let loaded = await store.load(handle: handle)
            guard let self, observationIdentifier == identifier else { return }
            observationIdentifier = nil
            observationTask = nil
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
        scheduleNextWake()
    }

    private func finalizeObservedDecision() {
        let identifier = UUID()
        observationIdentifier = identifier
        let finalize = environment.finalizeNativeDecision
        let handle = handle
        observationTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let result = await finalize(handle)
            guard let self, observationIdentifier == identifier else { return }
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
        scheduleNextWake()
    }

    private func finishObservation() {
        guard isLifecycleMonitoredState else { return }
        guard environment.now() < terminalDeadline else {
            finish()
            return
        }
        observationDelay = nextDelay(after: observationDelay)
        observationUptime = wakeUptime(after: observationDelay)
        scheduleNextWake()
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
        cancelForeground()
        lifecycle = .staged
        if restartObservation {
            stopObservation()
            startObservation()
        }
        if shouldNotify { onEvent?(.presentation(.waiting)) }
        scheduleNextWake()
    }

    private func cancelForeground() {
        foregroundIdentifier = nil
        foregroundTask?.cancel()
        foregroundTask = nil
        foregroundWake = nil
    }

    private func stopObservation() {
        observationIdentifier = nil
        observationTask?.cancel()
        observationTask = nil
        observationUptime = nil
    }

    private func scheduleForeground(_ action: ForegroundWake, after delay: UInt64) {
        foregroundWake = (action, wakeUptime(after: delay))
        scheduleNextWake()
    }

    private func wakeUptime(after delay: UInt64) -> TimeInterval {
        environment.uptime() + min(
            max(0, terminalDeadline.timeIntervalSince(environment.now())),
            Double(delay) / 1_000_000_000
        )
    }

    private func scheduleNextWake() {
        var candidates = [ScheduledWake]()
        if let foregroundWake {
            candidates.append(ScheduledWake(purpose: .foreground, uptime: foregroundWake.uptime))
        }
        if let observationUptime {
            candidates.append(ScheduledWake(purpose: .observation, uptime: observationUptime))
        }
        if state == .awaitingAuthentication {
            candidates.append(ScheduledWake(
                purpose: .authenticationExpiry,
                uptime: environment.uptime() + max(
                    0, terminalDeadline.timeIntervalSince(environment.now())
                )
            ))
        }
        let next = candidates.min { $0.uptime < $1.uptime }
        guard next != scheduledWake else { return }
        wakeIdentifier = nil
        wakeTask?.cancel()
        wakeTask = nil
        scheduledWake = next
        guard let next else { return }
        let identifier = UUID()
        wakeIdentifier = identifier
        let remaining = max(0, next.uptime - environment.uptime())
        let wait = environment.wait
        wakeTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            if next.purpose == .authenticationExpiry {
                do {
                    try await Task.sleep(for: .seconds(remaining))
                } catch {
                    return
                }
            } else {
                await wait(UInt64(min(remaining * 1_000_000_000, Double(UInt64.max))))
            }
            guard let self, wakeIdentifier == identifier else { return }
            wakeIdentifier = nil
            wakeTask = nil
            scheduledWake = nil
            handleWake(next)
        }
    }

    private func handleWake(_ wake: ScheduledWake) {
        switch wake.purpose {
        case .foreground:
            guard let scheduled = foregroundWake else { return }
            foregroundWake = nil
            switch scheduled.action {
            case .prepare:
                if environment.now() >= terminalDeadline { finish() }
                else { startForeground(.prepare) }
            case .persist:
                performPersistence()
            case .prepareAgain:
                guard case .persisting(let operation) = lifecycle,
                      case .respond(_, let delay) = operation.action else { return }
                if operation.cancellationRequested {
                    replacePersistence(.reject)
                } else {
                    lifecycle = .loading(retryDelay: delay)
                    if environment.now() >= terminalDeadline { finish() }
                    else { startForeground(.prepare) }
                }
            }
        case .observation:
            observationUptime = nil
            observe()
        case .authenticationExpiry:
            if state == .awaitingAuthentication,
               environment.now() >= terminalDeadline { finish() }
        }
        scheduleNextWake()
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
        scheduleNextWake()
        onEvent?(.presentation(presentation))
    }

    private func supersede() {
        finish(.superseded)
    }
}
