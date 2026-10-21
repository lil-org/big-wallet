// ∅ 2026 lil org

import Foundation

@MainActor
protocol NativeApprovalReviewTeardown: AnyObject {
    func invalidateNativeApprovalReview()
}

@MainActor
final class NativeApprovalReview {
    private struct Participant {
        weak var value: (any NativeApprovalReviewTeardown)?
    }

    fileprivate let approval: ApprovalReview
    private(set) var isActive = true
    private var participants = [ObjectIdentifier: Participant]()

    var request: SafariRequest { approval.request }
    var action: DappRequestAction { approval.action }
#if BW_SAFARI_VM_TESTING
    var fixtureOperation: SafariVMFixtures.Operation {
        SafariVMFixtures.shared.capture(handle: approval.binding.handle)
    }
#endif

    init(intent: BoundApprovalIntent) {
        approval = ApprovalReview(intent: intent)
    }

    func register(_ participant: any NativeApprovalReviewTeardown) {
        guard isActive else {
            participant.invalidateNativeApprovalReview()
            return
        }
        participants = participants.filter { $0.value.value != nil }
        participants[ObjectIdentifier(participant)] = Participant(value: participant)
    }

    func invalidate() {
        guard isActive else { return }
        isActive = false
        approval.invalidate()
        let activeParticipants = participants.values.compactMap(\.value)
        participants.removeAll()
        for participant in activeParticipants {
            participant.invalidateNativeApprovalReview()
        }
    }
}

protocol NativeDeliveryStore: AnyObject, Sendable {
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
    func completeNativeImmediate(
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID,
        resolution: ImmediateResolution
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
        case approval(NativeApprovalReview)
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

    struct Environment: Sendable {
        let now: @MainActor @Sendable () -> Date
        let uptime: @MainActor @Sendable () -> TimeInterval
        let wait: @MainActor @Sendable (UInt64) async -> Void
        let waitForAuthenticationExpiry: @MainActor @Sendable (TimeInterval) async throws -> Void
        let prepare: @MainActor @Sendable (ExtensionBridge.RequestBinding, WalletReviewCatalog?) -> DappRequestPreparation
        let reloadWallets: @MainActor @Sendable () async -> Bool
        let currentReviewCatalog: @MainActor @Sendable () -> WalletReviewCatalog?
        let attemptNativeDecision: @MainActor @Sendable (ReviewConsent) async -> NativeApprovalFinalizationResult

        init(
            now: @escaping @MainActor @Sendable () -> Date,
            uptime: (@MainActor @Sendable () -> TimeInterval)? = nil,
            wait: @escaping @MainActor @Sendable (UInt64) async -> Void,
            waitForAuthenticationExpiry: (@MainActor @Sendable (TimeInterval) async throws -> Void)? = nil,
            prepare: (@MainActor @Sendable (ExtensionBridge.RequestBinding, WalletReviewCatalog?) -> DappRequestPreparation)? = nil,
            reloadWallets: (@MainActor @Sendable () async -> Bool)? = nil,
            currentReviewCatalog: (@MainActor @Sendable () -> WalletReviewCatalog?)? = nil,
            attemptNativeDecision: (@MainActor @Sendable (ReviewConsent) async -> NativeApprovalFinalizationResult)? = nil
        ) {
            self.now = now
            self.uptime = uptime ?? { ProcessInfo.processInfo.systemUptime }
            self.wait = wait
            self.waitForAuthenticationExpiry = waitForAuthenticationExpiry ?? { seconds in
                let clock = ContinuousClock()
                try await clock.sleep(until: clock.now.advanced(by: .seconds(seconds)), tolerance: nil)
            }
            self.prepare = prepare ?? { DappRequestProcessor().prepare($0, catalog: $1) }
            self.reloadWallets = reloadWallets ?? { await WalletsManager.shared.reloadFromStore() }
            self.currentReviewCatalog = currentReviewCatalog ?? { WalletsManager.shared.reviewCatalog() }
            self.attemptNativeDecision = attemptNativeDecision ?? { _ in .pending }
        }

        static let live = Environment(
            now: { Date() },
            wait: { nanoseconds in
                let clock = ContinuousClock()
                try? await clock.sleep(until: clock.now.advanced(by: .nanoseconds(Int64(clamping: nanoseconds))), tolerance: nil)
            },
            attemptNativeDecision: { consent in
                await NativeApprovalFinalizer.shared.attempt(consent: consent)
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

    private enum RecoveryIntent {
        case validateReceipt
        case prepareReview
        case persistResponse(ImmediateResolution)
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
    var requiresExplicitReviewRetry: Bool {
        if case .paused(.prepareReview) = state { return hasAuthenticated }
        return false
    }
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

    isolated deinit {
        activeWork?.task.cancel()
        if case .reviewing(let review) = state { review.invalidate() }
    }

    func start(nativeDeliveryOwner: ExtensionBridge.NativeDeliveryOwner) {
        if runtime == nil { runtime = nativeDeliveryOwner }
        guard phase == .registered else { return }
        beginReceiptValidation()
    }

    func resumeAfterAuthentication() {
        guard isAwaitingAuthentication else { return }
        accessProgress = .authenticated
        beginReviewPreparation()
    }

    func retryRecovery() {
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

    func expireIfDormant() {
        if isExpiredDormant { finish() }
    }

    func cancelBeforeAuthentication() {
        guard !hasAuthenticated, state.canReject else { return }
        if case .acquiringReceipt = state {
            guard let work = activeWork?.context else { return }
            updateState(.acquiringReceipt(afterReceipt: .reject), within: work)
        } else {
            beginRejectionBeforeAuthentication()
        }
    }

    func approveAccounts(
        _ accounts: [SpecificWalletAccount],
        ethereumNetwork: EthereumNetwork?,
        review: NativeApprovalReview
    ) {
        let identities = accounts.map {
            WalletAccountDescriptor(walletID: $0.walletId, account: $0.account)
        }
        acceptReview(review) { review, approvedAt, receipt in
            review.acceptAccounts(
                selection: .init(accounts: identities, ethereumChainID: ethereumNetwork?.chainIdHexString),
                approvedAt: approvedAt,
                nativeReceipt: receipt
            )
        }
    }

    func approveMessage(solanaCluster: Solana.Cluster?, review: NativeApprovalReview) {
        guard isCurrent(review),
              case .approveMessage = review.action else { return }
        acceptReview(review) { review, approvedAt, receipt in
            review.acceptMessage(cluster: solanaCluster, approvedAt: approvedAt, nativeReceipt: receipt)
        }
    }

    func approveTransaction(
        _ transaction: Transaction,
        reviewedNetwork: ResolvedEthereumNetwork,
        review: NativeApprovalReview
    ) {
        guard isCurrent(review),
              case .approveTransaction(let action) = review.action else { return }
        guard let execution = DappApprovalDecision.TransactionExecution(
            transaction,
            reviewedNetwork: reviewedNetwork,
            approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account)
        ) else {
            failAndReject()
            return
        }
        acceptReview(review) { review, approvedAt, receipt in
            review.acceptTransaction(execution: execution, approvedAt: approvedAt, nativeReceipt: receipt)
        }
    }

    func approveAddEthereumChain(review: NativeApprovalReview) {
        acceptReview(review) { review, approvedAt, receipt in
            review.acceptAddEthereumChain(approvedAt: approvedAt, nativeReceipt: receipt)
        }
    }

    func reject() {
        beginRejection(reason: .user)
    }

    func reject(review: NativeApprovalReview) {
        guard isCurrent(review) else { return }
        reject()
    }

    private func isCurrent(_ review: NativeApprovalReview) -> Bool {
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

    private func acceptReview(
        _ review: NativeApprovalReview,
        using accept: (ApprovalReview, Date, ExtensionBridge.NativeDeliveryReceipt) -> ReviewConsent?
    ) {
        guard isCurrent(review), let runtime else { return }
        let approvedAt = environment.now()
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: nativeDeliveryNonce,
            owner: runtime
        )
        guard let consent = accept(review.approval, approvedAt, receipt) else {
            failAndReject()
            return
        }
        beginFinalization(consent)
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

    private func beginFinalization(_ consent: ReviewConsent) {
        transition(to: .finalizing) { work in
            await Self.finalize(work, consent: consent)
        }
    }

    private func beginExecutionObservation() {
        transition(to: .observingExecution) { work in
            await Self.observe(work, mode: .execution)
        }
    }

    private func beginResponsePersistence(_ response: ImmediateResolution) {
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
            if case .pending(let snapshot, .current) = status, let binding = snapshot.requestBinding {
                guard work.mayAttempt else { break }
                var preparation: DappRequestPreparation? = work.update { _ in
                    work.environment.prepare(binding, nil)
                }
                if case .needsCatalog? = preparation {
                    preparation = nil
                    if await work.environment.reloadWallets() {
                        guard work.mayAttempt else { break }
                        guard let refreshed = await work.load() else { return }
                        if finishIfResolved(refreshed, work: work) { return }
                        guard case .pending(let current, .current) = refreshed,
                              current.requestBinding == binding else { continue }
                        if let catalog = work.update({ _ in work.environment.currentReviewCatalog() }) ?? nil {
                            preparation = work.update { _ in work.environment.prepare(binding, catalog) }
                        }
                    }
                }
                guard work.mayAttempt else { break }
                if let preparation {
                    switch preparation {
                    case .needsCatalog, .unavailable:
                        work.update { $0.pause(for: .prepareReview) }
                    case .approval(let intent):
                        guard intent.binding == binding else {
                            work.update { $0.failAndReject() }
                            return
                        }
                        let review = NativeApprovalReview(intent: intent)
                        work.update {
                            $0.presentReview(review)
                        }
                    case .immediate(let response):
                        work.update {
                            $0.updateState(.persistingResponse, within: work)
                        }
                        await persistResponse(work, response: response)
                    }
                    return
                }
            }
            if !(await work.retry()) { break }
        }
        work.update { $0.pause(for: .prepareReview) }
    }

    private static func persistResponse(_ work: Work, response: ImmediateResolution) async {
        guard let runtime = work.runtime else { return }
        await persistOwnedMutation(work, recovery: .persistResponse(response)) {
            await work.store.completeNativeImmediate(
                handle: work.handle, nativeDeliveryNonce: work.nonce,
                runtimeInstanceIdentifier: runtime.runtimeInstanceIdentifier,
                resolution: response
            )
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

    private static func finalize(_ work: Work, consent: ReviewConsent) async {
        while work.isCurrent {
            guard let status = await work.load() else { return }
            switch status {
            case .pending(_, .current):
                guard work.update({ work.environment.now() < $0.terminalDeadline }) == true else {
                    work.update { $0.finish() }
                    return
                }
                let result = await work.environment.attemptNativeDecision(consent)
                guard work.isCurrent else { return }
                switch result {
                case .responseReady:
                    work.update { $0.finish() }
                case .interruptionRequired:
                    work.update { $0.beginInterruption() }
                case .reviewRequired:
                    work.update { $0.pause(for: .prepareReview) }
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
