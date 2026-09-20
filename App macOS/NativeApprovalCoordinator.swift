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
    func markNativeApprovalReady(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        approvedAt: Date
    ) async -> ExtensionBridge.StoreMutationResult
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
        case loading, reviewing, staging, responding, rejecting, waiting, paused, finished
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
        case pending(SafariRequest, ReceiptOwnership)
        case staged(ReceiptOwnership)
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
        let prepare: @MainActor (SafariRequest) -> DappRequestPreparation
        let finalizeNativeDecision: (
            ExtensionBridge.Handle, ExtensionBridge.NativeApprovalAuthorization
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
            prepare: @escaping @MainActor (SafariRequest) -> DappRequestPreparation = {
                DappRequestProcessor().prepare($0)
            },
            finalizeNativeDecision: @escaping (
                ExtensionBridge.Handle, ExtensionBridge.NativeApprovalAuthorization
            ) async -> NativeApprovalFinalizationResult = { _, _ in .pending
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
            finalizeNativeDecision: { handle, authorization in
                await NativeApprovalFinalizer.shared.finalize(handle: handle, authorization: authorization)
            }
        )
    }

    private enum Workflow {
        case validating, acquiringReceipt, awaitingAuthentication, loading, reviewing
        case staging(approvedAt: Date)
        case interrupting
        case responding(ResponseToExtension)
        case rejectingBeforeAuthentication(notifyOnStaged: Bool)
        case rejectingOwned
        case waiting

        var phase: Phase {
            switch self {
            case .validating: .validating
            case .acquiringReceipt: .acquiringReceipt
            case .awaitingAuthentication: .awaitingAuthentication
            case .loading: .loading
            case .reviewing: .reviewing
            case .staging: .staging
            case .responding: .responding
            case .rejectingBeforeAuthentication, .rejectingOwned, .interrupting: .rejecting
            case .waiting: .waiting
            }
        }

        var recovery: Workflow {
            switch self {
            case .acquiringReceipt: .validating
            case .reviewing: .loading
            default: self
            }
        }

        var canReject: Bool {
            switch self {
            case .staging, .responding, .rejectingBeforeAuthentication, .rejectingOwned, .interrupting, .waiting:
                false
            default:
                true
            }
        }
    }

    private enum State {
        case registered
        case active(Workflow)
        case paused(Workflow)
        case finished

        var phase: Phase {
            switch self {
            case .registered: .registered
            case .active(let workflow): workflow.phase
            case .paused: .paused
            case .finished: .finished
            }
        }

        var canReject: Bool {
            switch self {
            case .registered: true
            case .active(let workflow), .paused(let workflow): workflow.canReject
            case .finished: false
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
            recoveryDeadline = environment.uptime() + 10
        }

        var isCurrent: Bool {
            !Task.isCancelled && owner?.work === self
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
            await environment.wait(UInt64(min(1, remaining) * 1_000_000_000))
            return mayAttempt
        }
    }

    let handle: ExtensionBridge.Handle
    let nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce
    var phase: Phase { state.phase }
    private(set) var peer: PeerMeta?
    private(set) var order: Order?
    private(set) var currentPresentation: PresentationSnapshot?
    var onEvent: ((Event) -> Void)?

    private let store: NativeDeliveryStore
    private let environment: Environment
    private var runtime: ExtensionBridge.NativeDeliveryOwner?
    private var work: Work?
    private var task: Task<Void, Never>?
    private var authorization: ExtensionBridge.NativeApprovalAuthorization?
    private var state = State.registered
    private var terminalDeadline: Date
    private var hasVerifiedReceipt = false
    private(set) var hasAuthenticated = false
    private var preauthenticationCancellationRequested = false

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

    deinit { task?.cancel() }

    func start(nativeDeliveryOwner: ExtensionBridge.NativeDeliveryOwner) {
        if runtime == nil { runtime = nativeDeliveryOwner }
        guard phase == .registered else { return }
        run(.validating)
    }

    func resumeAfterAuthentication() {
        guard isAwaitingAuthentication else { return }
        hasAuthenticated = true
        run(.loading)
    }

    func preparePresentationForReactivation() {
        guard canReactivate, currentPresentation == nil else { return }
        presentWaiting()
    }

    func retryRecovery() {
        guard case .paused(let workflow) = state else { return }
        guard environment.now() < terminalDeadline else {
            finish()
            return
        }
        if !hasAuthenticated {
            if preauthenticationCancellationRequested {
                run(.rejectingBeforeAuthentication(notifyOnStaged: true))
            } else {
                run(.validating)
            }
        } else {
            run(workflow.recovery)
            presentWaiting()
        }
    }

    func expireIfDormant() {
        if isExpiredDormant { finish() }
    }

    func cancelBeforeAuthentication() {
        guard !hasAuthenticated, !isFinished, !preauthenticationCancellationRequested else { return }
        preauthenticationCancellationRequested = true
        guard phase != .acquiringReceipt else { return }
        run(.rejectingBeforeAuthentication(notifyOnStaged: false))
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
        beginRejection(presentation: .waiting)
    }

    private func beginRejection(presentation: Presentation) {
        guard state.canReject, !preauthenticationCancellationRequested else { return }
        if !hasAuthenticated {
            cancelBeforeAuthentication()
        } else {
            run(.rejectingOwned)
            publishPresentation(presentation)
        }
    }

    private func stage(_ decision: DappApprovalDecision) {
        guard phase == .reviewing, let runtime else { return }
        let approvedAt = environment.now()
        authorization = .init(
            receipt: .init(nativeDeliveryNonce: nativeDeliveryNonce, owner: runtime),
            decision: decision,
            approvedAt: approvedAt
        )
        run(.staging(approvedAt: approvedAt))
        presentWaiting()
    }

    private func run(_ workflow: Workflow) {
        guard !isFinished else { return }
        stopWork()
        state = .active(workflow)
        let work = Work(owner: self)
        self.work = work
        task = Task { await Self.perform(workflow, work: work) }
    }

    private static func perform(_ workflow: Workflow, work: Work) async {
        switch workflow {
        case .validating, .acquiringReceipt:
            await validateAndAcquireReceipt(work)
        case .awaitingAuthentication:
            await awaitAuthenticationExpiry(work)
        case .loading:
            await prepareReview(work)
        case .staging(let approvedAt):
            await persistStage(work, approvedAt: approvedAt)
        case .interrupting:
            await persistInterruption(work)
        case .responding(let response):
            await persistResponse(work, response: response)
        case .rejectingBeforeAuthentication(let notifyOnStaged):
            await rejectBeforeAuthentication(work, notifyOnStaged: notifyOnStaged)
        case .rejectingOwned:
            await rejectOwned(work)
        case .reviewing, .waiting:
            await observe(work)
        }
    }

    private func stopWork() {
        work = nil
        task?.cancel()
        task = nil
    }

    private func pause() {
        guard case .active(let workflow) = state else { return }
        if authorization != nil {
            interruptApproval()
            return
        }
        stopWork()
        guard environment.now() < terminalDeadline else {
            finish()
            return
        }
        state = .paused(workflow)
        if hasAuthenticated { publishPresentation(.retryRequired) }
    }

    private func awaitAuthentication(notify: Bool = true) {
        run(.awaitingAuthentication)
        if notify { onEvent?(.authenticationRequired) }
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

    private func presentWaiting() {
        publishPresentation(.waiting)
    }

    private func publishPresentation(_ presentation: Presentation) {
        switch (currentPresentation?.presentation, presentation) {
        case (.waiting?, .waiting), (.retryRequired?, .retryRequired),
             (.rejecting?, .rejecting), (.interrupted?, .interrupted),
             (.finished?, .finished), (.superseded?, .superseded):
            return
        default:
            break
        }
        currentPresentation = PresentationSnapshot(
            revision: (currentPresentation?.revision ?? 0) + 1,
            presentation: presentation
        )
        onEvent?(.presentationChanged)
    }

    private func enterWaiting() {
        guard authorization != nil else {
            interruptApproval()
            return
        }
        guard hasAuthenticated else {
            pause()
            return
        }
        run(.waiting)
        presentWaiting()
    }

    private func interruptApproval() {
        authorization = nil
        guard !isFinished else { return }
        run(.interrupting)
        publishPresentation(.rejecting)
    }

    private static func persistInterruption(_ work: Work) async {
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
                await work.environment.wait(1_000_000_000)
            }
        }
    }

    private func finish(_ presentation: Presentation = .finished) {
        guard !isFinished else { return }
        stopWork()
        authorization = nil
        state = .finished
        publishPresentation(presentation)
    }

    private func failAndReject() {
        beginRejection(presentation: .rejecting)
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
            case .queued(_, .staged): return .staged(ownership)
            case .queued(let request, _): return .pending(request, ownership)
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
            case .pending(_, .foreign), .staged(.foreign), .executing, .superseded:
                work.update { $0.finish(.superseded) }
                return
            case .responded, .missing:
                work.update { $0.finish() }
                return
            case .unavailable:
                if await work.retry() { continue }
                work.update { $0.pause() }
                return
            case .staged:
                work.update { $0.interruptApproval() }
                return
            case .pending:
                break
            }
            guard work.mayAttempt else { break }
            if work.update({ $0.preauthenticationCancellationRequested }) == true {
                await rejectBeforeAuthentication(work)
                return
            }
            work.update { $0.state = .active(.acquiringReceipt) }
            let result = await work.store.recordNativeDeliveryReceipt(
                handle: work.handle, nativeDeliveryNonce: work.nonce, owner: runtime
            )
            guard work.isCurrent else { return }
            if result == .persisted {
                work.update { $0.hasVerifiedReceipt = true }
                if work.update({ $0.preauthenticationCancellationRequested }) == true {
                    await rejectBeforeAuthentication(work)
                } else {
                    work.update { $0.awaitAuthentication() }
                }
                return
            }
            guard let current = await work.load() else { return }
            switch current {
            case .pending(_, .current), .staged(.current):
                work.update { $0.hasVerifiedReceipt = true }
                if work.update({ $0.preauthenticationCancellationRequested }) == true {
                    await rejectBeforeAuthentication(work)
                } else {
                    work.update { $0.awaitAuthentication() }
                }
                return
            case .responded, .missing, .executing, .superseded,
                 .pending(_, .foreign), .staged(.foreign):
                work.update { $0.finish() }
                return
            default:
                break
            }
            if work.update({ $0.preauthenticationCancellationRequested }) == true {
                await rejectBeforeAuthentication(work)
                return
            }
            if result == .ownershipLost { break }
            if !(await work.retry()) { break }
        }
        work.update { $0.pause() }
    }

    private static func prepareReview(_ work: Work) async {
        while work.mayAttempt {
            guard let status = await work.load() else { return }
            if finishIfResolved(status, work: work) { return }
            if case .pending(let request, .current) = status {
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
                            $0.run(.reviewing)
                            $0.publishPresentation(.approval(request: request, action: action))
                        }
                    case .response(let response):
                        work.update {
                            $0.state = .active(.responding(response))
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

    private static func persistStage(
        _ work: Work, approvedAt: Date
    ) async {
        guard let runtime = work.runtime else { return }
        await persistOwnedMutation(work, operation: {
            await work.store.markNativeApprovalReady(
                handle: work.handle, nativeDeliveryNonce: work.nonce,
                runtimeInstanceIdentifier: runtime.runtimeInstanceIdentifier,
                approvedAt: approvedAt
            )
        }, onPersisted: { $0.enterWaiting() })
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

    private static func rejectBeforeAuthentication(
        _ work: Work,
        notifyOnStaged: Bool = false
    ) async {
        work.update {
            $0.state = .active(.rejectingBeforeAuthentication(notifyOnStaged: notifyOnStaged))
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
            case .staged(.current):
                work.update { $0.interruptApproval() }
                return
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
                 .pending(_, .foreign), .staged(.foreign), .staged(.none):
                work.update { $0.finish() }
                return
            case .staged(.current):
                work.update { $0.interruptApproval() }
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
            guard let status = await work.load() else { return }
            if finishIfResolved(status, work: work) { return }
            guard work.mayAttempt else { break }
            guard case .pending(_, .current) = status else {
                if await work.retry() { continue }
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
        case .staged(.foreign):
            work.update { $0.finish(.superseded) }
        case .staged, .executing:
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

    private static func observe(_ work: Work) async {
        var delay: UInt64 = 1_000_000_000
        var outageDeadline: TimeInterval?
        while work.isCurrent {
            await work.environment.wait(delay)
            if let outageDeadline, work.environment.uptime() >= outageDeadline {
                work.update { $0.pause() }
                return
            }
            guard let status = await work.load() else { return }
            var unavailable = false
            switch status {
            case .staged(.foreign):
                work.update { $0.finish(.superseded) }
                return
            case .staged, .executing:
                work.update {
                    $0.state = .active(.waiting)
                    $0.presentWaiting()
                }
                guard let authorization = work.update({ $0.authorization }) ?? nil else {
                    work.update { $0.interruptApproval() }
                    return
                }
                let result = await work.environment.finalizeNativeDecision(work.handle, authorization)
                guard work.isCurrent else { return }
                if result == .responseReady || result == .interrupted {
                    work.update { $0.finish(result == .interrupted ? .interrupted : .finished) }
                    return
                }
                if result == .unavailable {
                    work.update { $0.interruptApproval() }
                    return
                }
            case .responded, .missing, .superseded,
                 .pending(_, .foreign), .pending(_, .none):
                work.update { $0.finish() }
                return
            case .unavailable:
                unavailable = true
            case .pending(_, .current):
                break
            }
            guard work.update({ work.environment.now() < $0.terminalDeadline }) == true else {
                work.update { $0.finish() }
                return
            }
            if unavailable {
                let now = work.environment.uptime()
                let deadline = outageDeadline ?? now + 10
                outageDeadline = deadline
                guard now < deadline else {
                    work.update { $0.pause() }
                    return
                }
                delay = UInt64(min(1, deadline - now) * 1_000_000_000)
            } else {
                outageDeadline = nil
                delay = min(delay * 2, 5_000_000_000)
            }
        }
    }
}
