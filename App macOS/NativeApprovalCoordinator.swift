// ∅ 2026 lil org

import Foundation

protocol NativeDeliveryStore: AnyObject {
    func load(
        handle: ExtensionBridge.Handle
    ) async -> ExtensionBridge.SnapshotResult
    func recordNativeDeliveryReceipt(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID
    ) async -> ExtensionBridge.StoreMutationResult
    func stageNativeDecision(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        decision: NativeApprovalDecision
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

    private enum PersistenceIntent {
        case rejection
        case response(ResponseToExtension)
    }

    enum State: Equatable {
        case loading
        case reviewing
        case staging
        case staged
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
    private(set) var state: State = .loading
    let nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce
    private(set) var peer: PeerMeta?
    var onDecisionStaged: (() -> Void)?
    var onFinished: (() -> Void)?
    var onFailure: (() -> Void)?

    private let store: NativeDeliveryStore
    private let environment: Environment
    private let runtimeInstanceIdentifier: UUID
    private let requiresExistingReceipt: Bool
    private var monitorTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var terminalDeadline: Date
    private var didNotifyFailure = false
    private var rejectIfDecisionIsNotStaged = false
    private var didEnterWaitingState = false

    init(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        store: NativeDeliveryStore = ExtensionBridge.shared,
        environment: Environment = .live,
        requiresExistingReceipt: Bool = false,
        initialState: State = .loading
    ) {
        self.handle = handle
        self.nativeDeliveryNonce = nativeDeliveryNonce
        self.runtimeInstanceIdentifier = runtimeInstanceIdentifier
        self.store = store
        self.environment = environment
        self.requiresExistingReceipt = requiresExistingReceipt
        state = initialState
        terminalDeadline = environment.now().addingTimeInterval(
            ExtensionBridge.requestTTL
        )
    }

    deinit {
        monitorTask?.cancel()
        persistenceTask?.cancel()
    }

    func loadPresentation() async -> Presentation {
        guard state == .loading else {
            switch state {
            case .staged:
                return .waiting
            case .rejecting:
                return .rejecting
            case .finished:
                return .finished
            case .loading, .reviewing, .staging:
                return .superseded
            }
        }

        var retryDelay = Self.initialRetryDelayNanoseconds
        while !Task.isCancelled, state == .loading {
            guard environment.now() < terminalDeadline else {
                finish()
                return .finished
            }
            if let presentation = await loadPresentationAttempt() {
                return presentation
            }
            guard environment.now() < terminalDeadline else {
                finish()
                return .finished
            }
            await waitBeforeDeadline(retryDelay)
            guard environment.now() < terminalDeadline else {
                finish()
                return .finished
            }
            retryDelay = nextDelay(after: retryDelay)
        }
        return state == .finished ? .finished : .superseded
    }

    private func loadPresentationAttempt() async -> Presentation? {
        switch await storedStatus() {
        case .pending(let request, let receipt):
            guard environment.now() < terminalDeadline else {
                finish()
                return .finished
            }
            guard receipt != .foreign else {
                supersede()
                return .superseded
            }
            guard !requiresExistingReceipt || receipt == .current else {
                supersede()
                return .superseded
            }
            let preparation: DappRequestPreparation
            if let walletIndependent = environment.prepareWithoutWallets(
                request
            ) {
                preparation = walletIndependent
            } else {
                guard environment.reloadWallets() else { return nil }
                preparation = environment.prepare(request)
            }
            guard environment.now() < terminalDeadline else {
                finish()
                return .finished
            }
            if receipt == .none {
                switch await recordReceipt() {
                case .persisted:
                    break
                case .ownershipLost, .retryablePersistenceFailure:
                    return nil
                }
            }
            guard environment.now() < terminalDeadline else {
                finish()
                return .finished
            }
            switch preparation {
            case .approval(let action):
                state = .reviewing
                startLifecycleMonitor()
                return .approval(
                    request: request,
                    action: action
                )
            case .response(let response):
                return await persistImmediateResponse(response)
            }
        case .staged:
            enterWaitingState(notify: false)
            return .waiting
        case .responded, .missing:
            finish()
            return .finished
        case .unavailable:
            return nil
        case .superseded:
            supersede()
            return .superseded
        }
    }

    func approveAccounts(
        _ accounts: [SpecificWalletAccount],
        ethereumNetwork: EthereumNetwork?
    ) {
        let identities = accounts.map {
            NativeApprovalDecision.AccountIdentity(
                walletID: $0.walletId,
                address: $0.account.address,
                provider: $0.account.coin.correspondingInpageProvider
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
        guard let execution = NativeApprovalDecision.TransactionExecution(
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
        case .loading, .reviewing:
            takeRejectionOwnership()
        case .staging:
            rejectIfDecisionIsNotStaged = true
        case .staged, .rejecting, .finished:
            break
        }
    }

    private func stage(_ decision: NativeApprovalDecision) {
        guard state == .reviewing else { return }
        state = .staging
        Task {
            var retryDelay = Self.initialRetryDelayNanoseconds
            for _ in 0..<3 {
                guard state == .staging else { return }
                if rejectIfDecisionIsNotStaged {
                    takeRejectionOwnership()
                    return
                }
                let result = await store.stageNativeDecision(
                    handle: handle,
                    nativeDeliveryNonce: nativeDeliveryNonce,
                    runtimeInstanceIdentifier: runtimeInstanceIdentifier,
                    decision: decision
                )
                guard state == .staging else { return }
                switch result {
                case .persisted:
                    enterWaitingState(notify: true)
                    return
                case .ownershipLost:
                    await reconcileAfterLostOwnership()
                    return
                case .retryablePersistenceFailure:
                    if rejectIfDecisionIsNotStaged {
                        takeRejectionOwnership()
                        return
                    }
                    guard state == .staging else { return }
                    await environment.wait(retryDelay)
                    guard state == .staging else { return }
                    retryDelay = nextDelay(after: retryDelay)
                }
            }
            if rejectIfDecisionIsNotStaged {
                takeRejectionOwnership()
                return
            }
            failAndReject()
        }
    }

    private func reconcileAfterLostOwnership() async {
        guard state == .staging else { return }
        switch await storedStatus() {
        case .staged:
            enterWaitingState(notify: true)
        case .responded, .missing:
            finish()
        case .pending, .unavailable, .superseded:
            failAndReject()
        }
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
                receipt = owner.runtimeInstanceIdentifier ==
                    runtimeInstanceIdentifier ? .current : .foreign
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

    private func recordReceipt() async -> ExtensionBridge.StoreMutationResult {
        await store.recordNativeDeliveryReceipt(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtimeInstanceIdentifier
        )
    }

    private func persist(_ intent: PersistenceIntent) async ->
        ExtensionBridge.StoreMutationResult {
        switch intent {
        case .rejection:
            return await store.rejectNativeDelivery(
                handle: handle,
                nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtimeInstanceIdentifier
            )
        case .response(let response):
            return await store.completeNativeDelivery(
                handle: handle,
                nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtimeInstanceIdentifier,
                response: response
            )
        }
    }

    private func persistImmediateResponse(
        _ response: ResponseToExtension
    ) async -> Presentation? {
        let intent = PersistenceIntent.response(response)
        var retryDelay = Self.initialRetryDelayNanoseconds
        for attempt in 0..<3 {
            guard environment.now() < terminalDeadline else {
                finish()
                return .finished
            }
            switch await persist(intent) {
            case .persisted:
                finish()
                return .finished
            case .ownershipLost:
                switch await storedStatus() {
                case .staged:
                    enterWaitingState(notify: false)
                    return .waiting
                case .responded, .missing:
                    finish()
                    return .finished
                case .superseded:
                    supersede()
                    return .superseded
                case .pending, .unavailable:
                    return nil
                }
            case .retryablePersistenceFailure:
                if attempt < 2 {
                    await waitBeforeDeadline(retryDelay)
                    retryDelay = nextDelay(after: retryDelay)
                }
            }
        }
        state = .rejecting
        notifyFailureOnce()
        startPersistence(
            intent,
            retryDelay: retryDelay,
            waitBeforeFirstAttempt: true
        )
        return .rejecting
    }

    private func failAndReject() {
        guard state != .rejecting, state != .finished else { return }
        notifyFailureOnce()
        takeRejectionOwnership()
    }

    private func takeRejectionOwnership() {
        state = .rejecting
        stopLifecycleMonitor()
        startPersistence(
            .rejection,
            retryDelay: Self.initialRetryDelayNanoseconds,
            waitBeforeFirstAttempt: false
        )
    }

    private func startPersistence(
        _ intent: PersistenceIntent,
        retryDelay: UInt64,
        waitBeforeFirstAttempt: Bool
    ) {
        guard persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            guard let self else { return }
            await persistUntilTerminal(
                intent,
                retryDelay: retryDelay,
                waitBeforeFirstAttempt: waitBeforeFirstAttempt
            )
        }
    }

    private func persistUntilTerminal(
        _ intent: PersistenceIntent,
        retryDelay: UInt64,
        waitBeforeFirstAttempt: Bool
    ) async {
        var retryDelay = retryDelay
        var shouldWait = waitBeforeFirstAttempt
        while !Task.isCancelled, state == .rejecting {
            guard environment.now() < terminalDeadline else {
                await reconcilePersistence(intent)
                if state == .rejecting { finish() }
                return
            }
            if shouldWait {
                await waitBeforeDeadline(retryDelay)
                guard !Task.isCancelled, state == .rejecting else { return }
                guard environment.now() < terminalDeadline else {
                    await reconcilePersistence(intent)
                    if state == .rejecting { finish() }
                    return
                }
            }
            switch await persist(intent) {
            case .persisted:
                finish()
                return
            case .ownershipLost:
                await reconcilePersistence(intent)
                if state != .rejecting { return }
            case .retryablePersistenceFailure:
                notifyFailureOnce()
                await reconcilePersistence(intent)
                if state != .rejecting { return }
            }
            shouldWait = true
            retryDelay = nextDelay(after: retryDelay)
        }
    }

    private func reconcilePersistence(_ intent: PersistenceIntent) async {
        guard state == .rejecting else { return }
        switch await storedStatus() {
        case .staged:
            let notify: Bool
            if case .rejection = intent {
                notify = true
            } else {
                notify = false
            }
            enterWaitingState(notify: notify)
        case .responded, .missing:
            finish()
        case .superseded:
            finish()
        case .pending(_, .current):
            break
        case .pending:
            finish()
        case .unavailable:
            notifyFailureOnce()
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
                switch await storedStatus() {
                case .staged:
                    switch await environment.finalizeNativeDecision(handle) {
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
        case .loading, .rejecting, .finished:
            return false
        }
    }

    private func enterWaitingState(notify: Bool) {
        guard state != .finished else { return }
        let shouldRestartLifecycleMonitor = state != .staged
        let shouldNotify = notify && !didEnterWaitingState
        didEnterWaitingState = true
        rejectIfDecisionIsNotStaged = false
        persistenceTask?.cancel()
        persistenceTask = nil
        state = .staged
        if shouldRestartLifecycleMonitor {
            stopLifecycleMonitor()
        }
        if shouldNotify {
            onDecisionStaged?()
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
        onFailure?()
    }

    private func finish() {
        guard state != .finished else { return }
        state = .finished
        stopLifecycleMonitor()
        persistenceTask?.cancel()
        persistenceTask = nil
        onFinished?()
    }

    private func supersede() {
        guard state != .finished else { return }
        state = .finished
        stopLifecycleMonitor()
        persistenceTask?.cancel()
        persistenceTask = nil
    }
}
