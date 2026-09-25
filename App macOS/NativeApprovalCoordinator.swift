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
    func interruptNativeApproval(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID
    ) async -> ExtensionBridge.NativeInterruptionResult
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
    enum Phase: Equatable {
        case registered, validating, acquiringReceipt, awaitingAuthentication
        case loading, reviewing, responding, rejecting, waiting, paused, finished
    }

    enum Presentation {
        case approval(request: SafariRequest, action: DappRequestAction)
        case waiting, retryRequired, rejecting, interrupted, finished, superseded

        var isTerminal: Bool {
            switch self {
            case .interrupted, .finished, .superseded: true
            case .approval, .waiting, .retryRequired, .rejecting: false
            }
        }
    }

    struct PresentationSnapshot {
        let revision: UInt64
        let presentation: Presentation
    }

    enum Event {
        case authenticationRequired
        case presentationChanged
    }

    private enum ReceiptOwnership {
        case none, current, foreign
    }

    private enum StoredStatus {
        case pending(ExtensionBridge.Snapshot, ReceiptOwnership)
        case executing
        case responded, missing, unavailable, superseded
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
        let prepare: @MainActor (SafariRequest) -> DappRequestPreparation?
        let attemptNativeDecision: (
            ExtensionBridge.Snapshot, ExtensionBridge.NativeApprovalAuthorization
        ) async ->
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
            prepare: @escaping @MainActor (SafariRequest) -> DappRequestPreparation? = {
                guard let catalog = WalletsManager.shared.reviewCatalog() else { return nil }
                return DappRequestProcessor().prepare($0, catalog: catalog)
            },
            attemptNativeDecision: @escaping (
                ExtensionBridge.Snapshot, ExtensionBridge.NativeApprovalAuthorization
            ) async -> NativeApprovalFinalizationResult = { _, _ in .pending
            }
        ) {
            self.now = now
            self.uptime = uptime
            self.wait = wait
            self.prepareWithoutWallets = prepareWithoutWallets
            self.reloadWallets = reloadWallets
            self.prepare = prepare
            self.attemptNativeDecision = attemptNativeDecision
        }

        static let live = Environment(
            now: Date.init,
            wait: { nanoseconds in
                try? await Task.sleep(nanoseconds: nanoseconds)
            },
            attemptNativeDecision: { snapshot, authorization in
                await NativeApprovalFinalizer.shared.attempt(snapshot: snapshot, authorization: authorization)
            }
        )
    }

    private enum AccessProgress {
        case unverified, receiptVerified, authenticated
    }

    private enum ReceiptContinuation {
        case authenticate, reject
    }

    private enum RejectionReason {
        case user, failure
    }

    private enum Completion {
        case finished, interrupted, superseded

        var presentation: Presentation {
            switch self {
            case .finished: .finished
            case .interrupted: .interrupted
            case .superseded: .superseded
            }
        }
    }

    private enum State {
        case registered, validating
        case acquiringReceipt(afterReceipt: ReceiptContinuation)
        case awaitingAuthentication
        case loading(showWaiting: Bool)
        case reviewing(request: SafariRequest, action: DappRequestAction)
        case waiting(ExtensionBridge.NativeApprovalAuthorization)
        case responding(ResponseToExtension, showWaiting: Bool)
        case rejectingBeforeAuthentication, interrupting
        case rejectingOwned(RejectionReason)
        indirect case paused(resuming: State)
        case finished(Completion)

        var phase: Phase {
            switch self {
            case .registered: .registered
            case .validating: .validating
            case .acquiringReceipt: .acquiringReceipt
            case .awaitingAuthentication: .awaitingAuthentication
            case .loading: .loading
            case .reviewing: .reviewing
            case .waiting: .waiting
            case .responding: .responding
            case .rejectingBeforeAuthentication, .rejectingOwned, .interrupting: .rejecting
            case .paused: .paused
            case .finished: .finished
            }
        }

        var retryState: State? {
            switch self {
            case .validating, .acquiringReceipt(.authenticate): .validating
            case .acquiringReceipt(.reject), .rejectingBeforeAuthentication: .rejectingBeforeAuthentication
            case .loading, .reviewing: .loading(showWaiting: true)
            case .responding(let response, _): .responding(response, showWaiting: true)
            case .rejectingOwned: .rejectingOwned(.user)
            case .registered, .awaitingAuthentication, .waiting,
                 .interrupting, .paused, .finished: nil
            }
        }

        func presentation(hasAuthenticated: Bool) -> Presentation? {
            switch self {
            case .registered, .validating, .acquiringReceipt,
                 .awaitingAuthentication, .rejectingBeforeAuthentication:
                nil
            case .loading(let showWaiting), .responding(_, let showWaiting):
                showWaiting ? .waiting : nil
            case .reviewing(let request, let action):
                .approval(request: request, action: action)
            case .waiting, .rejectingOwned(.user):
                .waiting
            case .rejectingOwned(.failure), .interrupting:
                .rejecting
            case .paused:
                hasAuthenticated ? .retryRequired : nil
            case .finished(let completion):
                completion.presentation
            }
        }

        var showingWaiting: State {
            switch self {
            case .loading: .loading(showWaiting: true)
            case .responding(let response, _): .responding(response, showWaiting: true)
            default: self
            }
        }

        var authorization: ExtensionBridge.NativeApprovalAuthorization? {
            switch self {
            case .waiting(let authorization): authorization
            default: nil
            }
        }

        var rejectsBeforeAuthentication: Bool {
            switch self {
            case .acquiringReceipt(.reject), .rejectingBeforeAuthentication,
                 .paused(resuming: .rejectingBeforeAuthentication): true
            default: false
            }
        }

        var canReject: Bool {
            switch self {
            case .registered, .validating, .acquiringReceipt(.authenticate),
                 .awaitingAuthentication, .loading, .reviewing: true
            case .paused(let resuming): resuming.canReject
            default: false
            }
        }
    }

    @MainActor
    private final class Work {
        weak var owner: NativeApprovalCoordinator?
        let store: NativeDeliveryStore
        let environment: Environment
        let handle: ExtensionBridge.Handle
        let nonce: ExtensionBridge.NativeDeliveryNonce
        let runtime: ExtensionBridge.NativeDeliveryOwner?
        let recoveryDeadline: TimeInterval

        init(owner: NativeApprovalCoordinator) {
            self.owner = owner
            store = owner.store
            environment = owner.environment
            handle = owner.handle
            nonce = owner.nativeDeliveryNonce
            runtime = owner.runtime
            recoveryDeadline = environment.uptime() + NativeApprovalTiming.recoveryTimeout
        }

        var isCurrent: Bool {
            !Task.isCancelled && owner?.activeWork?.context === self
        }

        var mayAttempt: Bool {
            isCurrent && environment.uptime() < recoveryDeadline &&
                owner.map { environment.now() < $0.terminalDeadline } == true
        }

        @discardableResult
        func update<Value>(_ body: (NativeApprovalCoordinator) -> Value) -> Value? {
            guard isCurrent, let owner else { return nil }
            return body(owner)
        }

        func load() async -> StoredStatus? {
            guard isCurrent else { return nil }
            let loaded = await store.load(handle: handle)
            return update { $0.storedStatus(loaded) }
        }

        func retry() async -> Bool {
            guard mayAttempt else { return false }
            let remaining = min(
                recoveryDeadline - environment.uptime(),
                owner.map { $0.terminalDeadline.timeIntervalSince(environment.now()) } ?? 0
            )
            guard remaining > 0 else { return false }
            await environment.wait(UInt64(
                min(NativeApprovalTiming.recoveryRetryInterval, remaining) * 1_000_000_000
            ))
            return mayAttempt
        }
    }

    private struct ActiveWork {
        let context: Work
        let task: Task<Void, Never>
    }

    let handle: ExtensionBridge.Handle
    let nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce
    var phase: Phase { state.phase }
    private(set) var peer: PeerMeta?
    private(set) var order: Order?
    var currentPresentation: PresentationSnapshot? {
        state.presentation(hasAuthenticated: hasAuthenticated).map {
            PresentationSnapshot(revision: presentationRevision, presentation: $0)
        }
    }
    var onEvent: ((Event) -> Void)?

    private let store: NativeDeliveryStore
    private let environment: Environment
    private var runtime: ExtensionBridge.NativeDeliveryOwner?
    private var activeWork: ActiveWork?
    private var state = State.registered
    private var presentationRevision: UInt64 = 0
    private var terminalDeadline: Date
    private var accessProgress = AccessProgress.unverified

    private var hasVerifiedReceipt: Bool { accessProgress != .unverified }
    var hasAuthenticated: Bool { accessProgress == .authenticated }

    var isAwaitingAuthentication: Bool { phase == .awaitingAuthentication }
    var isFinished: Bool { phase == .finished }
    var isPaused: Bool { phase == .paused }
    var isDormant: Bool { isPaused && !hasAuthenticated }
    var canReactivate: Bool {
        hasAuthenticated && !isFinished && phase != .rejecting
    }
    var countsTowardUnverifiedLimit: Bool { !isFinished && !hasVerifiedReceipt }
    var isExpiredDormant: Bool {
        isPaused && environment.now() >= terminalDeadline
    }

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
        terminalDeadline = environment.now().addingTimeInterval(ExtensionBridge.requestTTL)
    }

    deinit { activeWork?.task.cancel() }

    func start(nativeDeliveryOwner: ExtensionBridge.NativeDeliveryOwner) {
        if runtime == nil { runtime = nativeDeliveryOwner }
        guard phase == .registered else { return }
        transition(to: .validating)
    }

    func resumeAfterAuthentication() {
        guard isAwaitingAuthentication else { return }
        accessProgress = .authenticated
        transition(to: .loading(showWaiting: false))
    }

    func preparePresentationForReactivation() {
        guard canReactivate, currentPresentation == nil else { return }
        transition(to: state.showingWaiting, continuing: activeWork?.context)
    }

    func retryRecovery() {
        guard case .paused(let resuming) = state else { return }
        guard environment.now() < terminalDeadline else {
            finish()
            return
        }
        transition(to: resuming)
    }

    func expireIfDormant() {
        if isExpiredDormant { finish() }
    }

    func cancelBeforeAuthentication() {
        guard !hasAuthenticated, state.canReject else { return }
        if case .acquiringReceipt = state {
            transition(to: .acquiringReceipt(afterReceipt: .reject), continuing: activeWork?.context)
        } else {
            transition(to: .rejectingBeforeAuthentication)
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
        approve(.accountSelection(.init(
            accounts: identities,
            ethereumChainID: ethereumNetwork?.chainIdHexString
        )))
    }

    func approveMessage(solanaCluster: Solana.Cluster?) {
        guard case .reviewing(_, .approveMessage(let action)) = state else { return }
        approve(.message(.init(
            approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account),
            solanaCluster: solanaCluster
        )))
    }

    func approveTransaction(
        _ transaction: Transaction,
        reviewedNetwork: ResolvedEthereumNetwork
    ) {
        guard case .reviewing(_, .approveTransaction(let action)) = state else { return }
        guard let execution = DappApprovalDecision.TransactionExecution(
            transaction,
            reviewedNetwork: reviewedNetwork,
            approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account)
        ) else {
            failAndReject()
            return
        }
        approve(.transaction(execution))
    }

    func approveAddEthereumChain() {
        approve(.addEthereumChain)
    }

    func reject() {
        beginRejection(reason: .user)
    }

    private func beginRejection(reason: RejectionReason) {
        guard state.canReject else { return }
        if !hasAuthenticated {
            cancelBeforeAuthentication()
        } else {
            transition(to: .rejectingOwned(reason))
        }
    }

    private func approve(_ decision: DappApprovalDecision) {
        guard phase == .reviewing, let runtime else { return }
        let approvedAt = environment.now()
        let authorization = ExtensionBridge.NativeApprovalAuthorization(
            receipt: .init(nativeDeliveryNonce: nativeDeliveryNonce, owner: runtime),
            decision: decision,
            approvedAt: approvedAt
        )
        transition(to: .waiting(authorization))
    }

    private func transition(to state: State, continuing work: Work? = nil) {
        guard !isFinished else { return }
        if let work, !work.isCurrent { return }
        let previousPresentation = currentPresentation?.presentation
        if work == nil { stopWork() }
        self.state = state
        switch state {
        case .registered, .paused, .finished:
            stopWork()
        default:
            if work == nil {
                let context = Work(owner: self)
                activeWork = ActiveWork(
                    context: context,
                    task: Task { await Self.perform(state, work: context) }
                )
            }
        }
        if let presentation = state.presentation(hasAuthenticated: hasAuthenticated),
           Self.presentationChanged(from: previousPresentation, to: presentation) {
            presentationRevision += 1
            onEvent?(.presentationChanged)
        }
        if case .awaitingAuthentication = state {
            onEvent?(.authenticationRequired)
        }
    }

    private static func perform(_ state: State, work: Work) async {
        guard work.isCurrent else { return }
        switch state {
        case .validating, .acquiringReceipt:
            await validateAndAcquireReceipt(work)
        case .awaitingAuthentication:
            await awaitAuthenticationExpiry(work)
        case .loading:
            await prepareReview(work)
        case .interrupting:
            await persistInterruption(work)
        case .responding(let response, _):
            await persistResponse(work, response: response)
        case .rejectingBeforeAuthentication:
            await rejectBeforeAuthentication(work)
        case .rejectingOwned:
            await rejectOwned(work)
        case .reviewing:
            await observe(work)
        case .waiting:
            await observe(work, immediately: true)
        case .registered, .paused, .finished:
            break
        }
    }

    private func stopWork() {
        let previous = activeWork
        activeWork = nil
        previous?.task.cancel()
    }

    private func pause() {
        if state.authorization != nil {
            interruptApproval()
            return
        }
        guard let retryState = state.retryState else { return }
        guard environment.now() < terminalDeadline else {
            finish()
            return
        }
        transition(to: .paused(resuming: retryState))
    }

    private func recordVerifiedReceipt() {
        if accessProgress == .unverified { accessProgress = .receiptVerified }
    }

    private func awaitAuthentication() {
        transition(to: .awaitingAuthentication)
    }

    private static func awaitAuthenticationExpiry(_ work: Work) async {
        while work.isCurrent {
            let remaining = work.update {
                $0.terminalDeadline.timeIntervalSince(work.environment.now())
            } ?? 0
            guard remaining > 0 else {
                work.update { $0.finish() }
                return
            }
            do { try await Task.sleep(for: .seconds(remaining)) }
            catch { return }
        }
    }

    private static func presentationChanged(from previous: Presentation?, to presentation: Presentation) -> Bool {
        switch (previous, presentation) {
        case (.waiting?, .waiting), (.retryRequired?, .retryRequired),
             (.rejecting?, .rejecting), (.interrupted?, .interrupted),
             (.finished?, .finished), (.superseded?, .superseded):
            false
        default:
            true
        }
    }

    private func enterWaiting() {
        guard let authorization = state.authorization else {
            interruptApproval()
            return
        }
        transition(to: .waiting(authorization))
    }

    private func interruptApproval() {
        guard !isFinished else { return }
        transition(to: .interrupting)
    }

    private static func persistInterruption(_ work: Work) async {
        work.update { $0.transition(to: .interrupting, continuing: work) }
        guard let runtime = work.runtime else {
            work.update { $0.finish(.interrupted) }
            return
        }
        while work.isCurrent {
            let result = await work.store.interruptNativeApproval(
                handle: work.handle,
                nativeDeliveryNonce: work.nonce,
                runtimeInstanceIdentifier: runtime.runtimeInstanceIdentifier
            )
            guard work.isCurrent else { return }
            switch result {
            case .interrupted:
                work.update { $0.finish(.interrupted) }
                return
            case .responseReady:
                work.update { $0.finish() }
                return
            case .ownershipLost:
                work.update { $0.finish(.superseded) }
                return
            case .retryablePersistenceFailure:
                guard work.update({ work.environment.now() < $0.terminalDeadline }) == true else {
                    work.update { $0.finish(.interrupted) }
                    return
                }
                await work.environment.wait(NativeApprovalTiming.recoveryRetryNanoseconds)
            }
        }
    }

    private func finish(_ completion: Completion = .finished) {
        transition(to: .finished(completion))
    }

    private func failAndReject() {
        beginRejection(reason: .failure)
    }

    private func storedStatus(_ loaded: ExtensionBridge.SnapshotResult) -> StoredStatus {
        switch loaded {
        case .missing: return .missing
        case .unavailable: return .unavailable
        case .found(let snapshot):
            guard snapshot.nativeDeliveryNonce == nativeDeliveryNonce else { return .superseded }
            if let request = snapshot.request {
                terminalDeadline = min(terminalDeadline, request.admissionDeadline)
            }
            peer = snapshot.request?.peerMeta ?? PeerMeta(title: snapshot.host)
            order = Order(createdAt: snapshot.createdAt, sequence: snapshot.sequence)
            let ownership: ReceiptOwnership
            if let receipt = snapshot.nativeDeliveryReceipt {
                ownership = receipt.nativeDeliveryNonce == nativeDeliveryNonce &&
                    receipt.owner.runtimeInstanceIdentifier == runtime?.runtimeInstanceIdentifier
                    ? .current : .foreign
            } else {
                ownership = .none
            }
            switch snapshot.state {
            case .responded: return .responded
            case .approving: return ownership == .foreign ? .superseded : .executing
            case .queued: return .pending(snapshot, ownership)
            }
        }
    }

    private static func validateAndAcquireReceipt(_ work: Work) async {
        guard let runtime = work.runtime else {
            work.update { $0.pause() }
            return
        }
        while work.mayAttempt {
            guard let status = await work.load() else { return }
            switch status {
            case .pending(_, .foreign), .executing, .superseded:
                work.update { $0.finish(.superseded) }
                return
            case .responded, .missing:
                work.update { $0.finish() }
                return
            case .unavailable:
                if await work.retry() { continue }
                work.update { $0.pause() }
                return
            case .pending:
                break
            }
            guard work.mayAttempt else { break }
            if work.update({ $0.state.rejectsBeforeAuthentication }) == true {
                await rejectBeforeAuthentication(work)
                return
            }
            work.update {
                $0.transition(to: .acquiringReceipt(afterReceipt: .authenticate), continuing: work)
            }
            let result = await work.store.recordNativeDeliveryReceipt(
                handle: work.handle, nativeDeliveryNonce: work.nonce, owner: runtime
            )
            guard work.isCurrent else { return }
            if result == .persisted {
                await continueAfterReceiptAcquired(work)
                return
            }
            guard let current = await work.load() else { return }
            switch current {
            case .pending(_, .current):
                await continueAfterReceiptAcquired(work)
                return
            case .responded, .missing, .executing, .superseded,
                 .pending(_, .foreign):
                work.update { $0.finish() }
                return
            default:
                break
            }
            if work.update({ $0.state.rejectsBeforeAuthentication }) == true {
                await rejectBeforeAuthentication(work)
                return
            }
            if result == .ownershipLost { break }
            if !(await work.retry()) { break }
        }
        work.update { $0.pause() }
    }

    private static func continueAfterReceiptAcquired(_ work: Work) async {
        work.update { $0.recordVerifiedReceipt() }
        if work.update({ $0.state.rejectsBeforeAuthentication }) == true {
            await rejectBeforeAuthentication(work)
        } else {
            work.update { $0.awaitAuthentication() }
        }
    }

    private static func prepareReview(_ work: Work) async {
        while work.mayAttempt {
            guard let status = await work.load() else { return }
            if finishIfResolved(status, work: work) { return }
            if case .pending(let snapshot, .current) = status, let request = snapshot.request {
                guard work.mayAttempt else { break }
                let preparation = work.update { owner -> DappRequestPreparation? in
                    if let independent = work.environment.prepareWithoutWallets(request) {
                        return independent
                    }
                    guard work.environment.reloadWallets() else { return nil }
                    return work.environment.prepare(request)
                } ?? nil
                guard work.mayAttempt else { break }
                if let preparation {
                    switch preparation {
                    case .approval(let action):
                        work.update {
                            $0.transition(to: .reviewing(request: request, action: action))
                        }
                    case .response(let response):
                        work.update {
                            $0.transition(
                                to: .responding(response, showWaiting: $0.currentPresentation != nil),
                                continuing: work
                            )
                        }
                        await persistResponse(work, response: response)
                    }
                    return
                }
            }
            if !(await work.retry()) { break }
        }
        work.update { $0.pause() }
    }

    private static func persistResponse(_ work: Work, response: ResponseToExtension) async {
        guard let runtime = work.runtime else { return }
        await persistOwnedMutation(work, operation: {
            await work.store.completeNativeDelivery(
                handle: work.handle, nativeDeliveryNonce: work.nonce,
                runtimeInstanceIdentifier: runtime.runtimeInstanceIdentifier,
                response: response
            )
        }, onPersisted: { $0.finish() })
    }

    private static func rejectBeforeAuthentication(_ work: Work) async {
        work.update {
            $0.transition(to: .rejectingBeforeAuthentication, continuing: work)
        }
        while work.isCurrent {
            guard let status = await work.load() else { return }
            let owned: Bool
            switch status {
            case .pending(_, .current): owned = true
            case .pending(_, .none):
                guard work.update({ !$0.hasVerifiedReceipt }) == true else {
                    work.update { $0.finish(.superseded) }
                    return
                }
                owned = false
            case .unavailable:
                if await work.retry() { continue }
                work.update { $0.pause() }
                return
            default:
                work.update { $0.finish() }
                return
            }
            guard work.mayAttempt else { break }
            let result: ExtensionBridge.StoreMutationResult
            if owned {
                guard let runtime = work.runtime else {
                    work.update { $0.pause() }
                    return
                }
                result = await work.store.rejectNativeDelivery(
                    handle: work.handle, nativeDeliveryNonce: work.nonce,
                    runtimeInstanceIdentifier: runtime.runtimeInstanceIdentifier
                )
            } else {
                result = await work.store.reject(handle: work.handle)
            }
            guard work.isCurrent else { return }
            if result == .persisted {
                work.update { $0.finish() }
                return
            }
            guard let current = await work.load() else { return }
            switch current {
            case .responded, .missing, .executing, .superseded,
                 .pending(_, .foreign):
                work.update { $0.finish() }
                return
            default: break
            }
            if !(await work.retry()) { break }
        }
        work.update { $0.pause() }
    }

    private static func rejectOwned(_ work: Work) async {
        guard let runtime = work.runtime else { return }
        await persistOwnedMutation(work, operation: {
            await work.store.rejectNativeDelivery(
                handle: work.handle, nativeDeliveryNonce: work.nonce,
                runtimeInstanceIdentifier: runtime.runtimeInstanceIdentifier
            )
        }, onPersisted: { $0.finish() })
    }

    private static func persistOwnedMutation(
        _ work: Work,
        operation: () async -> ExtensionBridge.StoreMutationResult,
        onPersisted: (NativeApprovalCoordinator) -> Void
    ) async {
        while work.isCurrent {
            guard work.mayAttempt else {
                guard let status = await work.load() else { return }
                if finishIfResolved(status, work: work) { return }
                break
            }
            let result = await operation()
            guard work.isCurrent else { return }
            if result == .persisted {
                work.update(onPersisted)
                return
            }
            guard let current = await work.load() else { return }
            if finishIfResolved(current, work: work) { return }
            if result == .ownershipLost { break }
            if !(await work.retry()) { break }
        }
        work.update { $0.pause() }
    }

    private static func finishIfResolved(_ status: StoredStatus, work: Work) -> Bool {
        switch status {
        case .executing:
            work.update { $0.enterWaiting() }
        case .responded, .missing:
            work.update { $0.finish() }
        case .superseded, .pending(_, .foreign), .pending(_, .none):
            work.update { $0.finish(.superseded) }
        case .pending(_, .current), .unavailable:
            return false
        }
        return true
    }

    private static func observe(_ work: Work, immediately: Bool = false) async {
        var delay = NativeApprovalTiming.observationInitialDelayNanoseconds
        var outageDeadline: TimeInterval?
        var shouldWait = !immediately
        while work.isCurrent {
            if shouldWait { await work.environment.wait(delay) }
            if let outageDeadline, work.environment.uptime() >= outageDeadline {
                work.update { $0.pause() }
                return
            }
            guard let status = await work.load() else { return }
            var unavailable = false
            switch status {
            case .executing:
                guard let authorization = work.update({ $0.state.authorization }) ?? nil else {
                    work.update { $0.interruptApproval() }
                    return
                }
                work.update {
                    $0.transition(to: .waiting(authorization), continuing: work)
                }
            case .responded, .missing, .superseded,
                 .pending(_, .foreign), .pending(_, .none):
                work.update { $0.finish() }
                return
            case .unavailable:
                unavailable = true
            case .pending(let snapshot, .current):
                if let authorization = work.update({ $0.state.authorization }) ?? nil {
                    guard work.update({ work.environment.now() < $0.terminalDeadline }) == true else {
                        work.update { $0.finish() }
                        return
                    }
                    let result = await work.environment.attemptNativeDecision(snapshot, authorization)
                    guard work.isCurrent else { return }
                    switch result {
                    case .responseReady:
                        work.update { $0.finish() }
                        return
                    case .interruptionRequired:
                        await persistInterruption(work)
                        return
                    case .pending:
                        break
                    }
                }
            }
            guard work.update({ work.environment.now() < $0.terminalDeadline }) == true else {
                work.update { $0.finish() }
                return
            }
            if unavailable {
                let now = work.environment.uptime()
                let deadline = outageDeadline ?? now + NativeApprovalTiming.recoveryTimeout
                outageDeadline = deadline
                guard now < deadline else {
                    work.update { $0.pause() }
                    return
                }
                delay = UInt64(
                    min(NativeApprovalTiming.recoveryRetryInterval, deadline - now) * 1_000_000_000
                )
            } else {
                outageDeadline = nil
                if shouldWait {
                    delay = min(delay * 2, NativeApprovalTiming.observationMaximumDelayNanoseconds)
                }
            }
            shouldWait = true
        }
    }
}
