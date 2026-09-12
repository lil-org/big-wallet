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
        case registered
        case validating
        case acquiringReceipt(cancelRequested: Bool)
        case awaitingAuthentication
        case cancelingBeforeAuthentication(receiptOwned: Bool)
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
    private(set) var state: State = .registered
    let nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce
    private(set) var peer: PeerMeta?
    private(set) var order: Order?
    var onEvent: ((Event) -> Void)?

    private let store: NativeDeliveryStore
    private let environment: Environment
    private var runtime: Runtime?
    private var bootstrapTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var terminalDeadline: Date
    private var didNotifyFailure = false
    private var rejectIfDecisionIsNotStaged = false
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
        state = .validating
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
              let runtime else {
            finish()
            return
        }
        order = Order(createdAt: snapshot.createdAt, sequence: snapshot.sequence)
        terminalDeadline = environment.now().addingTimeInterval(
            ExtensionBridge.requestTTL
        )
        recordDeadline(from: snapshot.request)
        state = .acquiringReceipt(cancelRequested: false)
        var retryDelay = Self.initialRetryDelayNanoseconds
        while !Task.isCancelled, environment.now() < terminalDeadline {
            let result = await store.recordNativeDeliveryReceipt(
                handle: handle,
                nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtime.instanceIdentifier,
                owner: runtime.owner
            )
            guard case .acquiringReceipt(let cancelRequested) = state else {
                return
            }
            switch result {
            case .persisted:
                bootstrapTask = nil
                if cancelRequested {
                    beginPreauthenticationCancellation(receiptOwned: true)
                } else {
                    state = .awaitingAuthentication
                    onEvent?(.authenticationRequired)
                }
                return
            case .ownershipLost:
                finish()
                return
            case .retryablePersistenceFailure:
                await waitBeforeDeadline(retryDelay)
                retryDelay = nextDelay(after: retryDelay)
            }
        }
        if case .acquiringReceipt = state { finish() }
    }

    func resumeAfterAuthentication() {
        guard state == .awaitingAuthentication else { return }
        terminalDeadline = environment.now().addingTimeInterval(
            ExtensionBridge.requestTTL
        )
        state = .loading
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
            state = .acquiringReceipt(cancelRequested: true)
        case .awaitingAuthentication:
            beginPreauthenticationCancellation(receiptOwned: true)
        default:
            break
        }
    }

    private func beginPreauthenticationCancellation(receiptOwned: Bool) {
        state = .cancelingBeforeAuthentication(receiptOwned: receiptOwned)
        terminalDeadline = environment.now().addingTimeInterval(
            ExtensionBridge.requestTTL
        )
        persistenceTask = Task { [weak self] in
            await self?.cancelUntilTerminal(receiptOwned: receiptOwned)
        }
    }

    private func cancelUntilTerminal(receiptOwned: Bool) async {
        let expectedState = State.cancelingBeforeAuthentication(
            receiptOwned: receiptOwned
        )
        var retryDelay = Self.initialRetryDelayNanoseconds
        while !Task.isCancelled, state == expectedState,
              environment.now() < terminalDeadline {
            let loaded = await store.load(handle: handle)
            guard state == expectedState else { return }
            switch loaded {
            case .found(let snapshot):
                guard snapshot.nativeDeliveryNonce == nativeDeliveryNonce,
                      snapshot.phase != .responded else {
                    finish()
                    return
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
                        return
                    }
                    if snapshot.nativeDecisionStaged {
                        restoreAuthenticationWaiting()
                        return
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
                        return
                    }
                    result = await store.reject(handle: handle)
                }
                guard state == expectedState else { return }
                if result == .persisted {
                    finish()
                    return
                }
            case .missing:
                finish()
                return
            case .unavailable:
                break
            }
            await waitBeforeDeadline(retryDelay)
            retryDelay = nextDelay(after: retryDelay)
        }
        guard state == expectedState else { return }
        if receiptOwned {
            restoreAuthenticationWaiting()
        } else {
            finish()
        }
    }

    private func restoreAuthenticationWaiting() {
        persistenceTask = nil
        state = .awaitingAuthentication
    }

    private func preparePresentation() async {
        guard state == .loading else { return }

        var retryDelay = Self.initialRetryDelayNanoseconds
        while !Task.isCancelled, state == .loading {
            guard environment.now() < terminalDeadline else {
                finish()
                return
            }
            if await preparePresentationAttempt() { return }
            guard !Task.isCancelled, state == .loading else { return }
            guard environment.now() < terminalDeadline else {
                finish()
                return
            }
            await waitBeforeDeadline(retryDelay)
            guard environment.now() < terminalDeadline else {
                finish()
                return
            }
            retryDelay = nextDelay(after: retryDelay)
        }
    }

    private func preparePresentationAttempt() async -> Bool {
        let status = await storedStatus()
        guard state == .loading else { return false }
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
                state = .reviewing
                startLifecycleMonitor()
                bootstrapTask = nil
                onEvent?(.presentation(.approval(request: request, action: action)))
                return true
            case .response(let response):
                return await persistImmediateResponse(response)
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
        case .registered, .validating, .acquiringReceipt,
             .awaitingAuthentication, .cancelingBeforeAuthentication:
            cancelBeforeAuthentication()
        case .loading, .reviewing:
            takeRejectionOwnership()
        case .staging:
            rejectIfDecisionIsNotStaged = true
        case .staged, .rejecting, .finished:
            break
        }
    }

    private func stage(_ decision: NativeApprovalDecision) {
        guard state == .reviewing, let runtime else { return }
        state = .staging
        bootstrapTask = Task {
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
                    runtimeInstanceIdentifier: runtime.instanceIdentifier,
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
        let status = await storedStatus()
        guard state == .staging else { return }
        switch status {
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

    private func persist(_ intent: PersistenceIntent) async ->
        ExtensionBridge.StoreMutationResult {
        guard let runtime else { return .ownershipLost }
        switch intent {
        case .rejection:
            return await store.rejectNativeDelivery(
                handle: handle,
                nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtime.instanceIdentifier
            )
        case .response(let response):
            return await store.completeNativeDelivery(
                handle: handle,
                nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtime.instanceIdentifier,
                response: response
            )
        }
    }

    private func persistImmediateResponse(
        _ response: ResponseToExtension
    ) async -> Bool {
        let intent = PersistenceIntent.response(response)
        var retryDelay = Self.initialRetryDelayNanoseconds
        for attempt in 0..<3 {
            guard state == .loading else { return false }
            guard environment.now() < terminalDeadline else {
                finish()
                return true
            }
            let result = await persist(intent)
            guard state == .loading else { return false }
            switch result {
            case .persisted:
                finish()
                return true
            case .ownershipLost:
                let status = await storedStatus()
                guard state == .loading else { return false }
                switch status {
                case .staged:
                    enterWaitingState(notify: true)
                    return true
                case .responded, .missing:
                    finish()
                    return true
                case .superseded:
                    supersede()
                    return true
                case .pending, .unavailable:
                    return false
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
        return true
    }

    private func failAndReject() {
        guard state != .rejecting, state != .finished else { return }
        notifyFailureOnce()
        takeRejectionOwnership()
    }

    private func takeRejectionOwnership() {
        state = .rejecting
        bootstrapTask?.cancel()
        bootstrapTask = nil
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
            let result = await persist(intent)
            guard state == .rejecting else { return }
            switch result {
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
        let status = await storedStatus()
        guard state == .rejecting else { return }
        switch status {
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
        rejectIfDecisionIsNotStaged = false
        persistenceTask?.cancel()
        persistenceTask = nil
        state = .staged
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
        state = .finished
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
