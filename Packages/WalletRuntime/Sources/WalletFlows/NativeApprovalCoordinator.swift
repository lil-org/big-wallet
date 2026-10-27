import Foundation
import WalletDomain
import WalletAuthority

@MainActor
public final class NativeApprovalCoordinator {
    public enum Phase: Equatable {
        case registered, validating, acquiringReceipt, awaitingAuthentication
        case loading, reviewing, responding, rejecting, waiting, paused, finished
    }

    public enum Presentation {
        case approval(NativeApprovalReview)
        case waiting, retryRequired, rejecting, interrupted, finished, superseded

        public var isTerminal: Bool {
            switch self {
            case .interrupted, .finished, .superseded: true
            case .approval, .waiting, .retryRequired, .rejecting: false
            }
        }
    }

    public struct PresentationSnapshot {
        public let revision: UInt64
        public let presentation: Presentation
    }

    public enum Event {
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

    public struct Order: Equatable {
        public let createdAt: Date
        public let sequence: Int
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

    private enum RecoveryIntent {
        case validateReceipt
        case prepareReview
        case persistResponse(NativeApprovalResponse)
        case rejectBeforeAuthentication
        case rejectOwned
    }

    private enum ObservationMode {
        case review
        case execution
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
        case registered
        case validatingReceipt
        case acquiringReceipt(afterReceipt: ReceiptContinuation)
        case awaitingAuthentication
        case preparingReview
        case reviewing(NativeApprovalReview)
        case finalizing, observingExecution
        case persistingResponse
        case rejectingBeforeAuthentication
        case rejectingOwned(RejectionReason)
        case interrupting
        case paused(RecoveryIntent)
        case finished(Completion)

        var phase: Phase {
            switch self {
            case .registered: .registered
            case .validatingReceipt: .validating
            case .acquiringReceipt: .acquiringReceipt
            case .awaitingAuthentication: .awaitingAuthentication
            case .preparingReview: .loading
            case .reviewing: .reviewing
            case .finalizing, .observingExecution: .waiting
            case .persistingResponse: .responding
            case .rejectingBeforeAuthentication, .rejectingOwned, .interrupting: .rejecting
            case .paused: .paused
            case .finished: .finished
            }
        }

        @MainActor
        func presentation(hasAuthenticated: Bool) -> Presentation? {
            switch self {
            case .registered, .validatingReceipt, .acquiringReceipt,
                 .awaitingAuthentication, .rejectingBeforeAuthentication:
                nil
            case .reviewing(let review):
                .approval(review)
            case .preparingReview, .finalizing, .observingExecution,
                 .persistingResponse, .rejectingOwned(.user):
                .waiting
            case .rejectingOwned(.failure), .interrupting:
                .rejecting
            case .paused:
                hasAuthenticated ? .retryRequired : nil
            case .finished(let completion):
                completion.presentation
            }
        }

        var rejectsBeforeAuthentication: Bool {
            switch self {
            case .acquiringReceipt(.reject), .rejectingBeforeAuthentication,
                 .paused(.rejectBeforeAuthentication):
                true
            default:
                false
            }
        }

        var canReject: Bool {
            switch self {
            case .registered, .validatingReceipt, .acquiringReceipt(.authenticate),
                 .awaitingAuthentication, .preparingReview, .reviewing,
                 .paused(.validateReceipt), .paused(.prepareReview): true
            default: false
            }
        }
    }

    @MainActor
    private final class Work {
        weak var owner: NativeApprovalCoordinator?
        let store: NativeDeliveryStore
        let environment: NativeApprovalAuthority
        let handle: RequestHandle
        let nonce: NativeDeliveryNonce
        let runtime: NativeDeliveryOwner?
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

    public let handle: RequestHandle
    public let nativeDeliveryNonce: NativeDeliveryNonce
    public var phase: Phase { state.phase }
    public private(set) var peer: PeerMeta?
    public private(set) var order: Order?
    public var currentPresentation: PresentationSnapshot? {
        state.presentation(hasAuthenticated: hasAuthenticated).map {
            PresentationSnapshot(revision: presentationRevision, presentation: $0)
        }
    }
    public var onEvent: ((Event) -> Void)?

    private let store: NativeDeliveryStore
    private let environment: NativeApprovalAuthority
    private var runtime: NativeDeliveryOwner?
    private var activeWork: ActiveWork?
    private var state = State.registered
    private var presentationRevision: UInt64 = 0
    private var terminalDeadline: Date
    private var accessProgress = AccessProgress.unverified
    private var walletAccess: WalletAccessSession?

    private var hasVerifiedReceipt: Bool { accessProgress != .unverified }
    public var hasAuthenticated: Bool {
        accessProgress == .authenticated && walletAccess.map(environment.permitsPresentation) == true
    }

    public var isAwaitingAuthentication: Bool { phase == .awaitingAuthentication }
    public var isFinished: Bool { phase == .finished }
    public var isPaused: Bool { phase == .paused }
    public var requiresExplicitReviewRetry: Bool {
        if case .paused(.prepareReview) = state { return hasAuthenticated }
        return false
    }
    public var isDormant: Bool { isPaused && !hasAuthenticated }
    public var canReactivate: Bool {
        hasAuthenticated && !isFinished && phase != .rejecting
    }
    public var countsTowardUnverifiedLimit: Bool { !isFinished && !hasVerifiedReceipt }
    public var isExpiredDormant: Bool {
        isPaused && environment.now() >= terminalDeadline
    }

    public init(authority: NativeApprovalAuthority) {
        handle = authority.handle
        nativeDeliveryNonce = authority.nativeDeliveryNonce
        store = authority.deliveryStore
        environment = authority
        terminalDeadline = authority.now().addingTimeInterval(ExtensionBridge.requestTTL)
    }

    isolated deinit {
        activeWork?.task.cancel()
        if case .reviewing(let review) = state { review.invalidate() }
    }

    public func start(nativeDeliveryOwner: NativeDeliveryOwner) {
        if runtime == nil { runtime = nativeDeliveryOwner }
        guard phase == .registered else { return }
        beginReceiptValidation()
    }

    public func resumeAfterAuthentication(authorization: WalletAccessSession) {
        guard isAwaitingAuthentication, environment.acceptAccess(authorization) else { return }
        walletAccess = authorization
        accessProgress = .authenticated
        beginReviewPreparation()
    }

    public func retryRecovery() {
        guard case .paused(let intent) = state else { return }
        guard environment.now() < terminalDeadline else {
            finish()
            return
        }
        switch intent {
        case .validateReceipt: beginReceiptValidation()
        case .prepareReview: beginReviewPreparation()
        case .persistResponse(let response): beginResponsePersistence(response)
        case .rejectBeforeAuthentication: beginRejectionBeforeAuthentication()
        case .rejectOwned: beginOwnedRejection(reason: .user)
        }
    }

    public func expireIfDormant() {
        if isExpiredDormant { finish() }
    }

    public func cancelBeforeAuthentication() {
        guard !hasAuthenticated, state.canReject else { return }
        if case .acquiringReceipt = state {
            guard let work = activeWork?.context else { return }
            updateState(.acquiringReceipt(afterReceipt: .reject), within: work)
        } else {
            beginRejectionBeforeAuthentication()
        }
    }

    public func approveAccounts(_ accounts: [SpecificWalletAccount], ethereumNetwork: EthereumNetwork?, review: NativeApprovalReview) {
        acceptReview(review) { review.approveAccounts(accounts, ethereumNetwork: ethereumNetwork) }
    }

    public func approveMessage(solanaCluster: Solana.Cluster?, review: NativeApprovalReview, authorization: WalletAuthenticationGrant) {
        guard case .approveMessage = review.action else { return }
        acceptReview(review) { review.approveMessage(solanaCluster: solanaCluster, authorization: authorization) }
    }

    public func approveTransaction(_ transaction: Transaction, reviewedNetwork: ResolvedEthereumNetwork,
                                   review: NativeApprovalReview, authorization: WalletAuthenticationGrant) {
        guard case .approveTransaction = review.action else { return }
        acceptReview(review) { review.approveTransaction(transaction, reviewedNetwork: reviewedNetwork, authorization: authorization) }
    }

    public func approveAddEthereumChain(review: NativeApprovalReview) {
        acceptReview(review) { review.approveAddEthereumChain() }
    }

    public func reject() {
        beginRejection(reason: .user)
    }

    public func reject(review: NativeApprovalReview) {
        guard isCurrentPresentation(review) else { return }
        reject()
    }

    private func canAccept(_ review: NativeApprovalReview) -> Bool {
        guard isCurrentPresentation(review) else { return false }
        guard hasAuthenticated else {
            failAndReject()
            return false
        }
        return true
    }

    private func isCurrentPresentation(_ review: NativeApprovalReview) -> Bool {
        guard case .reviewing(let current) = state else { return false }
        return current === review && review.isActive
    }

    private func beginRejection(reason: RejectionReason) {
        guard state.canReject else { return }
        if !hasAuthenticated {
            cancelBeforeAuthentication()
        } else {
            beginOwnedRejection(reason: reason)
        }
    }

    private func acceptReview(_ review: NativeApprovalReview, using accept: () -> NativeApprovalOperation?) {
        guard canAccept(review) else { return }
        guard let operation = accept() else {
            failAndReject()
            return
        }
        beginFinalization(operation)
    }

    private func transition(
        to state: State,
        run: (@MainActor (Work) async -> Void)? = nil
    ) {
        guard !isFinished else { return }
        let previousPresentation = currentPresentation?.presentation
        let previousReview: NativeApprovalReview?
        if case .reviewing(let review) = self.state { previousReview = review }
        else { previousReview = nil }
        let previousWork = activeWork
        activeWork = nil
        self.state = state
        if let run {
            let context = Work(owner: self)
            activeWork = ActiveWork(
                context: context,
                task: Task {
                    guard context.isCurrent else { return }
                    await run(context)
                }
            )
        }
        publishPresentationChange(from: previousPresentation) {
            previousReview?.invalidate()
            previousWork?.task.cancel()
        }
    }

    private func updateState(_ state: State, within work: Work) {
        guard !isFinished, work.isCurrent else { return }
        let previousPresentation = currentPresentation?.presentation
        self.state = state
        publishPresentationChange(from: previousPresentation)
    }

    private func publishPresentationChange(
        from previousPresentation: Presentation?,
        beforeNotification: () -> Void = {}
    ) {
        let changed = state.presentation(hasAuthenticated: hasAuthenticated).map {
            Self.presentationChanged(from: previousPresentation, to: $0)
        } ?? false
        if changed {
            presentationRevision += 1
        }
        let revision = presentationRevision
        let work = activeWork?.context
        beforeNotification()
        guard presentationRevision == revision, activeWork?.context === work else { return }
        if changed {
            onEvent?(.presentationChanged)
        }
        if case .awaitingAuthentication = state {
            onEvent?(.authenticationRequired)
        }
    }

    private func beginReceiptValidation() {
        transition(to: .validatingReceipt, run: Self.validateAndAcquireReceipt)
    }

    private func beginReviewPreparation() {
        transition(to: .preparingReview, run: Self.prepareReview)
    }

    private func presentReview(_ review: NativeApprovalReview) {
        transition(to: .reviewing(review)) { work in
            await Self.observe(work, mode: .review)
        }
    }

    private func beginFinalization(_ operation: NativeApprovalOperation) {
        transition(to: .finalizing) { work in
            await Self.finalize(work, operation: operation)
        }
    }

    private func beginExecutionObservation() {
        transition(to: .observingExecution) { work in
            await Self.observe(work, mode: .execution)
        }
    }

    private func beginResponsePersistence(_ response: NativeApprovalResponse) {
        transition(to: .persistingResponse) { work in
            await Self.persistResponse(work, response: response)
        }
    }

    private func beginRejectionBeforeAuthentication() {
        transition(to: .rejectingBeforeAuthentication, run: Self.rejectBeforeAuthentication)
    }

    private func beginOwnedRejection(reason: RejectionReason) {
        transition(to: .rejectingOwned(reason), run: Self.rejectOwned)
    }

    private func pause(for intent: RecoveryIntent) {
        guard environment.now() < terminalDeadline else {
            finish()
            return
        }
        transition(to: .paused(intent))
    }

    private func recordVerifiedReceipt() {
        if accessProgress == .unverified { accessProgress = .receiptVerified }
    }

    private func beginAuthenticationWait() {
        transition(to: .awaitingAuthentication, run: Self.awaitAuthenticationExpiry)
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
            do { try await work.environment.waitForAuthenticationExpiry(remaining) }
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

    private func beginInterruption() {
        transition(to: .interrupting, run: Self.persistInterruption)
    }

    private static func persistInterruption(_ work: Work) async {
        work.update { $0.updateState(.interrupting, within: work) }
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
            work.update {
                $0.pause(for: $0.state.rejectsBeforeAuthentication ? .rejectBeforeAuthentication : .validateReceipt)
            }
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
                work.update {
                    $0.pause(for: $0.state.rejectsBeforeAuthentication ? .rejectBeforeAuthentication : .validateReceipt)
                }
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
                $0.updateState(.acquiringReceipt(afterReceipt: .authenticate), within: work)
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
        work.update {
            $0.pause(for: $0.state.rejectsBeforeAuthentication ? .rejectBeforeAuthentication : .validateReceipt)
        }
    }

    private static func continueAfterReceiptAcquired(_ work: Work) async {
        work.update { $0.recordVerifiedReceipt() }
        if work.update({ $0.state.rejectsBeforeAuthentication }) == true {
            await rejectBeforeAuthentication(work)
        } else {
            work.update { $0.beginAuthenticationWait() }
        }
    }

    private static func prepareReview(_ work: Work) async {
        while work.mayAttempt {
            guard let status = await work.load() else { return }
            if finishIfResolved(status, work: work) { return }
            if case .pending(_, .current) = status, let runtime = work.runtime,
               let access = work.update({ $0.walletAccess }) ?? nil {
                let preparation = await work.environment.prepareReview(owner: runtime, access: access, until: work.recoveryDeadline)
                guard work.mayAttempt else { break }
                switch preparation {
                case .unavailable:
                    work.update { $0.pause(for: .prepareReview) }
                case .changed:
                    continue
                case .retry:
                    if await work.retry() { continue }
                    work.update { $0.pause(for: .prepareReview) }
                case .review(let review):
                    guard review.handle == work.handle else {
                        review.invalidate()
                        work.update { $0.failAndReject() }
                        return
                    }
                    work.update { $0.presentReview(review) }
                case .immediate(let response):
                    work.update { $0.updateState(.persistingResponse, within: work) }
                    await persistResponse(work, response: response)
                }
                return
            }
            if !(await work.retry()) { break }
        }
        work.update { $0.pause(for: .prepareReview) }
    }

    private static func persistResponse(_ work: Work, response: NativeApprovalResponse) async {
        await persistOwnedMutation(work, recovery: .persistResponse(response)) {
            await response.persistResponse()
        }
    }

    private static func rejectBeforeAuthentication(_ work: Work) async {
        work.update {
            $0.updateState(.rejectingBeforeAuthentication, within: work)
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
                work.update { $0.pause(for: .rejectBeforeAuthentication) }
                return
            default:
                work.update { $0.finish() }
                return
            }
            guard work.mayAttempt else { break }
            let result: ExtensionBridge.StoreMutationResult
            if owned {
                guard let runtime = work.runtime else {
                    work.update { $0.pause(for: .rejectBeforeAuthentication) }
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
        work.update { $0.pause(for: .rejectBeforeAuthentication) }
    }

    private static func rejectOwned(_ work: Work) async {
        guard let runtime = work.runtime else { return }
        await persistOwnedMutation(work, recovery: .rejectOwned) {
            await work.store.rejectNativeDelivery(
                handle: work.handle, nativeDeliveryNonce: work.nonce,
                runtimeInstanceIdentifier: runtime.runtimeInstanceIdentifier
            )
        }
    }

    private static func persistOwnedMutation(
        _ work: Work,
        recovery: RecoveryIntent,
        operation: () async -> ExtensionBridge.StoreMutationResult
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
                work.update { $0.finish() }
                return
            }
            guard let current = await work.load() else { return }
            if finishIfResolved(current, work: work) { return }
            if result == .ownershipLost { break }
            if !(await work.retry()) { break }
        }
        work.update { $0.pause(for: recovery) }
    }

    private static func finishIfResolved(_ status: StoredStatus, work: Work) -> Bool {
        switch status {
        case .executing:
            work.update { $0.beginInterruption() }
        case .responded, .missing:
            work.update { $0.finish() }
        case .superseded, .pending(_, .foreign), .pending(_, .none):
            work.update { $0.finish(.superseded) }
        case .pending(_, .current), .unavailable:
            return false
        }
        return true
    }

    private static func finalize(_ work: Work, operation: NativeApprovalOperation) async {
        while work.isCurrent {
            guard let status = await work.load() else { return }
            switch status {
            case .pending(_, .current):
                guard work.update({ work.environment.now() < $0.terminalDeadline }) == true else {
                    work.update { $0.finish() }
                    return
                }
                let result = await operation.attempt()
                guard work.isCurrent else { return }
                switch result {
                case .responseReady:
                    work.update { $0.finish() }
                case .interruptionRequired:
                    work.update { $0.beginInterruption() }
                case .reviewRequired:
                    work.update {
                        if $0.hasAuthenticated { $0.pause(for: .prepareReview) }
                        else { $0.beginOwnedRejection(reason: .user) }
                    }
                case .pending:
                    work.update {
                        if work.environment.now() < $0.terminalDeadline {
                            $0.beginExecutionObservation()
                        } else {
                            $0.finish()
                        }
                    }
                }
                return
            case .executing:
                work.update { $0.beginExecutionObservation() }
                return
            case .responded, .missing, .superseded,
                 .pending(_, .foreign), .pending(_, .none):
                work.update { $0.finish() }
                return
            case .unavailable:
                if await work.retry() { continue }
                work.update { $0.beginInterruption() }
                return
            }
        }
    }

    private static func observe(_ work: Work, mode: ObservationMode) async {
        var delay = NativeApprovalTiming.observationInitialDelayNanoseconds
        var outageDeadline: TimeInterval?
        while work.isCurrent {
            await work.environment.wait(delay)
            if let outageDeadline, work.environment.uptime() >= outageDeadline {
                handleObservationOutage(work, mode: mode)
                return
            }
            guard let status = await work.load() else { return }
            var unavailable = false
            switch status {
            case .executing:
                guard case .execution = mode else {
                    work.update { $0.beginInterruption() }
                    return
                }
            case .responded, .missing, .superseded,
                 .pending(_, .foreign), .pending(_, .none):
                work.update { $0.finish() }
                return
            case .unavailable:
                unavailable = true
            case .pending(_, .current):
                if case .execution = mode {
                    guard work.update({ work.environment.now() < $0.terminalDeadline }) == true else {
                        work.update { $0.finish() }
                        return
                    }
                    work.update { $0.beginInterruption() }
                    return
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
                    handleObservationOutage(work, mode: mode)
                    return
                }
                delay = UInt64(
                    min(NativeApprovalTiming.recoveryRetryInterval, deadline - now) * 1_000_000_000
                )
            } else {
                outageDeadline = nil
                delay = min(delay * 2, NativeApprovalTiming.observationMaximumDelayNanoseconds)
            }
        }
    }

    private static func handleObservationOutage(_ work: Work, mode: ObservationMode) {
        work.update { coordinator in
            switch mode {
            case .review: coordinator.pause(for: .prepareReview)
            case .execution: coordinator.beginInterruption()
            }
        }
    }
}

