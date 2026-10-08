// ∅ 2026 lil org

import Foundation

struct TransactionPreparationState: Equatable {

    enum Phase: String, Equatable, Encodable {
        case idle
        case preparing
        case ready
        case failed
        case editing
        case reserved
        case preflighting
        case finished
    }

    private(set) var phase: Phase = .idle
    private(set) var attemptID = 0
    private(set) var transactionID: UUID?

    var allowsMutation: Bool {
        switch phase {
        case .reserved, .preflighting, .finished:
            return false
        case .idle, .preparing, .ready, .failed, .editing:
            return true
        }
    }

    mutating func beginPreparation(for transactionID: UUID) -> Int {
        attemptID &+= 1
        self.transactionID = transactionID
        phase = .preparing
        return attemptID
    }

    mutating func beginEditing(_ transactionID: UUID) {
        attemptID &+= 1
        self.transactionID = transactionID
        phase = .editing
    }

    @discardableResult
    mutating func reserveForPreflight(for transactionID: UUID) -> Int? {
        guard phase == .ready,
              transactionID == self.transactionID else {
            return nil
        }
        attemptID &+= 1
        phase = .reserved
        return attemptID
    }

    @discardableResult
    mutating func beginPreflight(for transactionID: UUID) -> Int? {
        guard phase == .reserved,
              transactionID == self.transactionID else {
            return nil
        }
        phase = .preflighting
        return attemptID
    }

    func isCurrent(attemptID: Int, transactionID: UUID) -> Bool {
        attemptID == self.attemptID &&
            transactionID == self.transactionID
    }

    @discardableResult
    mutating func markReady(
        attemptID: Int,
        transactionID: UUID
    ) -> Bool {
        guard phase == .preparing,
              isCurrent(
                attemptID: attemptID,
                transactionID: transactionID
              ) else {
            return false
        }
        phase = .ready
        return true
    }

    @discardableResult
    mutating func markFailed(
        attemptID: Int,
        transactionID: UUID
    ) -> Bool {
        guard (phase == .preparing || phase == .preflighting),
              isCurrent(
                attemptID: attemptID,
                transactionID: transactionID
              ) else {
            return false
        }
        phase = .failed
        return true
    }

    @discardableResult
    mutating func restoreReady(
        attemptID: Int,
        transactionID: UUID
    ) -> Bool {
        guard phase == .reserved,
              isCurrent(
                  attemptID: attemptID,
                  transactionID: transactionID
              ) else {
            return false
        }
        self.attemptID &+= 1
        phase = .ready
        return true
    }

    @discardableResult
    mutating func beginUnsafeFeeEditing(
        attemptID: Int,
        transactionID: UUID
    ) -> Bool {
        guard phase == .preflighting,
              isCurrent(
                  attemptID: attemptID,
                  transactionID: transactionID
              ) else {
            return false
        }
        beginEditing(transactionID)
        return true
    }

    @discardableResult
    mutating func returnToReview(attemptID: Int, transactionID: UUID) -> Bool {
        guard phase == .preflighting,
              isCurrent(attemptID: attemptID, transactionID: transactionID) else { return false }
        self.attemptID &+= 1
        phase = .ready
        return true
    }

    func canApprove(
        transactionID: UUID,
        transactionIsReady: Bool
    ) -> Bool {
        phase == .ready &&
            transactionID == self.transactionID &&
            transactionIsReady
    }

    mutating func finish() {
        attemptID &+= 1
        transactionID = nil
        phase = .finished
    }

}

struct TransactionPreparationRestartGate: Equatable {

    private(set) var isPending = false

    @discardableResult
    mutating func recordMutation() -> Bool {
        guard !isPending else { return false }
        isPending = true
        return true
    }

    mutating func consume() -> Bool {
        guard isPending else { return false }
        isPending = false
        return true
    }

}

struct TransactionApprovalReservation: Equatable, Sendable {
    let attemptID: Int
    let transactionID: UUID
}

enum TransactionPreflightOutcome: Sendable {
    case approved(Transaction)
    case reviewRequired
    case invalidated
}

struct TransactionApprovalRequestToken: Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case preparation
        case preflight
    }

    let attemptID: Int
    let transactionID: UUID
    let kind: Kind
}

enum TransactionReviewNotice: Equatable, Sendable {
    case preparationFailed(TransactionPreparationFailure)
    case feesUpdated
    case unsafeFees
    case feesUnavailable

    var title: String {
        switch self {
        case .preparationFailed(.unsafeFees), .unsafeFees: Strings.unsafeFees
        case .preparationFailed, .feesUnavailable: Strings.somethingWentWrong
        case .feesUpdated: Strings.feesUpdated
        }
    }

    var message: String? {
        switch self {
        case .preparationFailed(.unsafeFees), .unsafeFees: Strings.unsafeFeesEdit
        case .preparationFailed, .feesUnavailable: nil
        case .feesUpdated: Strings.feesUpdatedReview
        }
    }

    var allowsRetry: Bool {
        switch self {
        case .preparationFailed(.unsafeFees), .unsafeFees, .feesUpdated: false
        case .preparationFailed, .feesUnavailable: true
        }
    }
}

struct TransactionApprovalSnapshot {
    let transaction: Transaction
    let phase: TransactionPreparationState.Phase
    let attemptID: Int
    let suggestedNonce: String?
    let latestWalletSuggestedFee: PreparedTransactionFee?
    let hasVerifiedFeeEstimate: Bool
    let hasGasSpeedInfo: Bool
    let gasSliderPosition: Double
    let speedPriorityFeePerGas: BigUInt?
    let allowsMutation: Bool
    let canApprove: Bool
    let canEdit: Bool
    let notice: TransactionReviewNotice?
    let canRetryPreparation: Bool
}

struct TransactionApprovalOperations: Sendable {
    typealias Prepare =
        @MainActor (Transaction, Bool, EthereumNetwork) -> AsyncThrowingStream<TransactionPreparationEvent, Error>
    typealias Preflight = @MainActor @Sendable (Transaction, EthereumNetwork) async throws -> TransactionFeePreflightResult

    let prepare: Prepare
    let preflight: Preflight

    nonisolated init(prepare: @escaping Prepare, preflight: @escaping Preflight) {
        self.prepare = prepare
        self.preflight = preflight
    }

    static func live(ethereum: Ethereum = .shared) -> TransactionApprovalOperations {
        TransactionApprovalOperations(
            prepare: { transaction, forceGasCheck, network in
                ethereum.prepareTransaction(transaction, forceGasCheck: forceGasCheck, network: network)
            },
            preflight: { transaction, network in
                try await ethereum.preflightTransactionFee(transaction, network: network)
            }
        )
    }
}

struct TransactionApprovalReducer {

    struct State {
        var transaction: Transaction
        let network: EthereumNetwork
        var preparation = TransactionPreparationState()
        var restartGate = TransactionPreparationRestartGate()
        var suggestedNonce: String?
        var verifiedFeeEstimate: GasService.Estimate?
        var gasSpeedConfiguration = GasSpeedConfiguration()
        var preparationForceGasCheck = false
        var isSliderInteractionActive = false
        var notice: TransactionReviewNotice?
    }

    struct PreflightStart {
        let token: TransactionApprovalRequestToken
        let snapshot: TransactionApprovalSnapshot
    }

    struct PreflightCompletion {
        let snapshot: TransactionApprovalSnapshot
        let outcome: TransactionPreflightOutcome
    }

    enum Event {
        case startPreparation(forceGasCheck: Bool)
        case preparationUpdate(
            TransactionApprovalRequestToken,
            Transaction
        )
        case preparationEstimate(
            TransactionApprovalRequestToken,
            GasService.Estimate
        )
        case preparationResult(
            TransactionApprovalRequestToken,
            Result<Transaction, TransactionPreparationFailure>
        )
        case reserveForPreflight
        case releaseReservation(TransactionApprovalReservation)
        case retryPreparation
        case applyEdits(Transaction.Edits)
        case sliderInteractionBegan
        case setFeeForSpeed(Double)
        case sliderInteractionEnded(cancelled: Bool)
        case finish
    }

    enum Effect {
        case cancelActiveRequest
        case clearActiveRequest(TransactionApprovalRequestToken)
        case runPreparation(
            TransactionApprovalRequestToken,
            Transaction,
            forceGasCheck: Bool
        )
        case snapshot(TransactionApprovalSnapshot)
    }

    private(set) var state: State

    init(
        transaction: Transaction,
        network: EthereumNetwork
    ) {
        state = State(
            transaction: transaction,
            network: network
        )
    }

    var snapshot: TransactionApprovalSnapshot {
        let transaction = state.transaction
        let canEdit: Bool
        if state.preparation.allowsMutation &&
            state.preparation.phase != .preparing {
            if case .automatic = transaction.feeIntent {
                canEdit = transaction.preparedFee != nil
                    || state.preparation.phase == .failed
            } else {
                canEdit = true
            }
        } else {
            canEdit = false
        }
        return TransactionApprovalSnapshot(
            transaction: transaction,
            phase: state.preparation.phase,
            attemptID: state.preparation.attemptID,
            suggestedNonce: state.suggestedNonce,
            latestWalletSuggestedFee: state.verifiedFeeEstimate?.suggestedFee(
                for: transaction.feeIntent
            ),
            hasVerifiedFeeEstimate: state.verifiedFeeEstimate != nil,
            hasGasSpeedInfo: state.gasSpeedConfiguration.info != nil,
            gasSliderPosition: state.gasSpeedConfiguration.sliderPosition(for: transaction),
            speedPriorityFeePerGas: state.gasSpeedConfiguration.speedPriorityFeePerGas(for: transaction),
            allowsMutation: state.preparation.allowsMutation,
            canApprove: state.preparation.canApprove(
                transactionID: transaction.id,
                transactionIsReady: transaction.isReadyForApproval(
                    on: state.network
                )
            ),
            canEdit: canEdit,
            notice: state.notice,
            canRetryPreparation: state.preparation.phase == .failed && state.notice?.allowsRetry == true
        )
    }

    func isCurrent(
        _ token: TransactionApprovalRequestToken
    ) -> Bool {
        guard state.preparation.isCurrent(
            attemptID: token.attemptID,
            transactionID: token.transactionID
        ) else {
            return false
        }
        switch token.kind {
        case .preparation:
            return state.preparation.phase == .preparing
        case .preflight:
            return state.preparation.phase == .preflighting
        }
    }

    private func acceptsPreparationUpdate(
        _ token: TransactionApprovalRequestToken
    ) -> Bool {
        guard token.kind == .preparation,
              state.preparation.isCurrent(
                attemptID: token.attemptID,
                transactionID: token.transactionID
              ) else {
            return false
        }
        return state.preparation.phase == .preparing ||
            state.preparation.phase == .ready
    }

    func isCurrent(_ reservation: TransactionApprovalReservation) -> Bool {
        state.preparation.phase == .reserved && state.preparation.isCurrent(
            attemptID: reservation.attemptID, transactionID: reservation.transactionID
        )
    }

    mutating func reduce(_ event: Event) -> [Effect] {
        switch event {
        case .startPreparation(let forceGasCheck):
            return startPreparation(forceGasCheck: forceGasCheck)
        case .preparationUpdate(let token, let transaction):
            return receivePreparationUpdate(transaction, token: token)
        case .preparationEstimate(let token, let estimate):
            return receivePreparationEstimate(estimate, token: token)
        case .preparationResult(let token, let result):
            return receivePreparationResult(result, token: token)
        case .reserveForPreflight:
            return reserveForPreflight()
        case .releaseReservation(let reservation):
            return releaseReservation(reservation)
        case .retryPreparation:
            guard snapshot.canRetryPreparation else { return [] }
            let forceGasCheck: Bool
            if case .preparationFailed = state.notice { forceGasCheck = state.preparationForceGasCheck }
            else { forceGasCheck = false }
            return startPreparation(forceGasCheck: forceGasCheck)
        case .applyEdits(let edits):
            return apply(edits)
        case .sliderInteractionBegan:
            return beginSliderInteraction()
        case .setFeeForSpeed(let value):
            return setFeeForSpeed(value: value)
        case .sliderInteractionEnded(let cancelled):
            return endSliderInteraction(cancelled: cancelled)
        case .finish:
            return finish()
        }
    }

    private mutating func startPreparation(
        forceGasCheck: Bool
    ) -> [Effect] {
        guard state.preparation.allowsMutation else { return [] }
        state.notice = nil
        state.restartGate = TransactionPreparationRestartGate()
        state.isSliderInteractionActive = false
        state.verifiedFeeEstimate = nil
        state.preparationForceGasCheck = forceGasCheck
        let transaction = state.transaction
        let attemptID = state.preparation.beginPreparation(
            for: transaction.id
        )
        let token = TransactionApprovalRequestToken(
            attemptID: attemptID,
            transactionID: transaction.id,
            kind: .preparation
        )
        return [
            .cancelActiveRequest,
            snapshotEffect(),
            .runPreparation(
                token,
                transaction,
                forceGasCheck: forceGasCheck
            ),
        ]
    }

    private mutating func receivePreparationUpdate(
        _ transaction: Transaction,
        token: TransactionApprovalRequestToken
    ) -> [Effect] {
        guard acceptsPreparationUpdate(token),
              transaction.id == token.transactionID else {
            return []
        }
        state.transaction = transaction
        state.suggestedNonce =
            state.suggestedNonce ?? transaction.decimalNonceString
        return [snapshotEffect()]
    }

    private mutating func receivePreparationEstimate(
        _ estimate: GasService.Estimate,
        token: TransactionApprovalRequestToken
    ) -> [Effect] {
        guard token.kind == .preparation, isCurrent(token) else {
            return []
        }
        install(estimate)
        return [snapshotEffect()]
    }

    private mutating func receivePreparationResult(
        _ result: Result<Transaction, TransactionPreparationFailure>,
        token: TransactionApprovalRequestToken
    ) -> [Effect] {
        guard token.kind == .preparation, isCurrent(token) else {
            return []
        }
        switch result {
        case .success(let prepared):
            guard prepared.id == token.transactionID,
                  state.preparation.markReady(
                    attemptID: token.attemptID,
                    transactionID: token.transactionID
                  ) else {
                return []
            }
            state.suggestedNonce =
                state.suggestedNonce ?? prepared.decimalNonceString
            return [snapshotEffect()]
        case .failure(let failure):
            guard state.preparation.markFailed(
                attemptID: token.attemptID,
                transactionID: token.transactionID
            ) else {
                return []
            }
            if state.verifiedFeeEstimate == nil {
                state.transaction.currentBaseFeePerGas = nil
                state.transaction.nextBaseFeePerGas = nil
            }
            state.notice = .preparationFailed(failure)
            return [.clearActiveRequest(token), snapshotEffect()]
        }
    }

    private mutating func reserveForPreflight() -> [Effect] {
        let transaction = state.transaction
        guard snapshot.canApprove,
              state.preparation.reserveForPreflight(for: transaction.id) != nil else { return [] }
        return [.cancelActiveRequest, snapshotEffect()]
    }

    private mutating func releaseReservation(_ reservation: TransactionApprovalReservation) -> [Effect] {
        guard isCurrent(reservation), state.preparation.restoreReady(
            attemptID: reservation.attemptID, transactionID: reservation.transactionID
        ) else { return [] }
        return [snapshotEffect()]
    }

    mutating func beginPreflight(
        _ reservation: TransactionApprovalReservation
    ) -> PreflightStart? {
        guard isCurrent(reservation),
              let attemptID = state.preparation.beginPreflight(
                for: state.transaction.id
              ) else { return nil }
        state.notice = nil
        let token = TransactionApprovalRequestToken(
            attemptID: attemptID,
            transactionID: state.transaction.id,
            kind: .preflight
        )
        return PreflightStart(token: token, snapshot: synchronizedSnapshot())
    }

    mutating func completePreflight(
        _ token: TransactionApprovalRequestToken,
        result: TransactionFeePreflightResult
    ) -> PreflightCompletion? {
        guard token.kind == .preflight, isCurrent(token) else { return nil }
        let outcome: TransactionPreflightOutcome
        switch result {
        case .safe(let transaction, let estimate):
            guard transaction.id == token.transactionID else { return nil }
            install(transaction, estimate: estimate)
            state.notice = nil
            state.restartGate = TransactionPreparationRestartGate()
            state.preparation.finish()
            outcome = .approved(state.transaction)
        case .walletManagedUpdated(let transaction, let estimate):
            guard transaction.id == token.transactionID,
                  state.preparation.returnToReview(
                    attemptID: token.attemptID, transactionID: token.transactionID
                  ) else { return nil }
            install(transaction, estimate: estimate)
            state.notice = .feesUpdated
            outcome = .reviewRequired
        case .userControlledUnsafe(let transaction, let estimate):
            guard transaction.id == token.transactionID,
                  state.preparation.beginUnsafeFeeEditing(
                    attemptID: token.attemptID, transactionID: token.transactionID
                  ) else { return nil }
            install(transaction, estimate: estimate)
            state.notice = .unsafeFees
            outcome = .reviewRequired
        case .unavailable(let transaction, let estimate):
            guard transaction.id == token.transactionID,
                  state.preparation.markFailed(
                    attemptID: token.attemptID, transactionID: token.transactionID
                  ) else { return nil }
            install(transaction, estimate: estimate)
            state.notice = .feesUnavailable
            outcome = .reviewRequired
        }
        return PreflightCompletion(snapshot: synchronizedSnapshot(), outcome: outcome)
    }

    private mutating func apply(_ edits: Transaction.Edits) -> [Effect] {
        let previousTransaction = state.transaction
        guard snapshot.canEdit, state.transaction.apply(edits) else {
            return []
        }
        state.gasSpeedConfiguration.commitAppliedEdits(
            edits,
            from: previousTransaction,
            to: state.transaction
        )
        state.notice = nil
        state.restartGate = TransactionPreparationRestartGate()
        state.isSliderInteractionActive = false
        state.preparation.beginEditing(state.transaction.id)
        return [
            .cancelActiveRequest,
            snapshotEffect(),
        ]
    }

    private mutating func beginSliderInteraction() -> [Effect] {
        guard state.preparation.allowsMutation else { return [] }
        state.gasSpeedConfiguration.markGasSliderInteraction()
        state.isSliderInteractionActive = true
        return []
    }

    private mutating func setFeeForSpeed(value: Double) -> [Effect] {
        guard state.preparation.allowsMutation,
              state.transaction.feeBasisBaseFeePerGas != nil,
              let info = state.gasSpeedConfiguration.info else { return [] }
        state.gasSpeedConfiguration.markGasSliderInteraction()
        let previousFee = state.transaction.preparedFee
        let previousProvenance = state.transaction.feeProvenance
        let previousPosition = state.gasSpeedConfiguration.sliderPosition(for: state.transaction)
        state.transaction.setFeeForSpeed(
            value: value,
            inRelationTo: info
        )
        state.gasSpeedConfiguration.recordSelectedSliderPosition(value, for: state.transaction)
        guard state.transaction.preparedFee != previousFee ||
                state.transaction.feeProvenance != previousProvenance else {
            let position = state.gasSpeedConfiguration.sliderPosition(for: state.transaction)
            return position != previousPosition ? [snapshotEffect()] : []
        }
        state.gasSpeedConfiguration.markGasSliderFeeChange()

        guard state.isSliderInteractionActive else {
            state.notice = nil
            return startPreparation(forceGasCheck: false)
        }

        var effects = [Effect]()
        if state.restartGate.recordMutation() {
            state.notice = nil
            state.preparation.beginEditing(state.transaction.id)
            effects.append(.cancelActiveRequest)
        }
        effects.append(snapshotEffect())
        return effects
    }

    private mutating func endSliderInteraction(
        cancelled: Bool
    ) -> [Effect] {
        state.isSliderInteractionActive = false
        let hadPendingMutation = state.restartGate.consume()
        let didInstallPendingQuote = state.gasSpeedConfiguration.endGasSliderInteraction(
            didChangeFee: !cancelled && hadPendingMutation
        )
        guard hadPendingMutation, !cancelled, state.preparation.allowsMutation else {
            return didInstallPendingQuote ? [snapshotEffect()] : []
        }
        return startPreparation(forceGasCheck: false)
    }

    private mutating func finish() -> [Effect] {
        state.notice = nil
        state.restartGate = TransactionPreparationRestartGate()
        state.isSliderInteractionActive = false
        state.preparation.finish()
        return [.cancelActiveRequest, snapshotEffect()]
    }

    private mutating func install(
        _ transaction: Transaction,
        estimate: GasService.Estimate
    ) {
        state.transaction = transaction
        state.suggestedNonce =
            state.suggestedNonce ?? transaction.decimalNonceString
        install(estimate)
    }

    private mutating func install(_ estimate: GasService.Estimate) {
        state.verifiedFeeEstimate = estimate
        estimate.applyBaseFeeContext(to: &state.transaction)
        state.gasSpeedConfiguration.applyFetchedEstimate(estimate)
    }

    private mutating func snapshotEffect() -> Effect {
        .snapshot(synchronizedSnapshot())
    }

    private mutating func synchronizedSnapshot() -> TransactionApprovalSnapshot {
        if let priorityFee = state.gasSpeedConfiguration.speedPriorityFeePerGas(for: state.transaction) {
            state.gasSpeedConfiguration.installTransactionFallback(feePerGas: priorityFee)
        }
        state.gasSpeedConfiguration.synchronizeSelectedSliderPosition(with: state.transaction)
        return snapshot
    }

}

@MainActor
final class TransactionApprovalCoordinator {
    private struct PreflightResolution: Sendable {
        let attemptID: Int
        let outcome: TransactionPreflightOutcome
    }

    private final class PreparationRequest {
        let token: TransactionApprovalRequestToken
        var task: Task<Void, Never>?

        init(token: TransactionApprovalRequestToken) {
            self.token = token
        }
    }

    private final class PreflightRequest {
        let token: TransactionApprovalRequestToken
        var task: Task<Void, Never>?
        private var continuation: CheckedContinuation<PreflightResolution, Never>?

        init(
            token: TransactionApprovalRequestToken,
            continuation: CheckedContinuation<PreflightResolution, Never>
        ) {
            self.token = token
            self.continuation = continuation
        }

        func resolve(_ resolution: PreflightResolution) {
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(returning: resolution)
        }
    }

    private enum ActiveRequest {
        case preparation(PreparationRequest)
        case preflight(PreflightRequest)

        var token: TransactionApprovalRequestToken {
            switch self {
            case .preparation(let request): request.token
            case .preflight(let request): request.token
            }
        }

        func cancel(attemptID: Int) {
            switch self {
            case .preparation(let request):
                request.task?.cancel()
            case .preflight(let request):
                request.task?.cancel()
                request.resolve(.init(attemptID: attemptID, outcome: .invalidated))
            }
        }
    }

    private var reducer: TransactionApprovalReducer
    private let operations: TransactionApprovalOperations
    private var activeRequest: ActiveRequest?
    var onSnapshot: (TransactionApprovalSnapshot) -> Void

    init(
        transaction: Transaction,
        network: EthereumNetwork,
        operations: TransactionApprovalOperations = .live(),
        onSnapshot: @escaping (TransactionApprovalSnapshot) -> Void = { _ in }
    ) {
        reducer = TransactionApprovalReducer(transaction: transaction, network: network)
        self.operations = operations
        self.onSnapshot = onSnapshot
    }

    var snapshot: TransactionApprovalSnapshot { reducer.snapshot }

    func startPreparation(forceGasCheck: Bool) {
        send(.startPreparation(forceGasCheck: forceGasCheck))
    }

    func reserveForPreflight() -> TransactionApprovalReservation? {
        let effects = reducer.reduce(.reserveForPreflight)
        guard !effects.isEmpty else { return nil }
        let reservation = TransactionApprovalReservation(
            attemptID: snapshot.attemptID, transactionID: snapshot.transaction.id
        )
        run(effects)
        return reducer.isCurrent(reservation) ? reservation : nil
    }

    @discardableResult
    func releaseReservation(_ reservation: TransactionApprovalReservation) -> Bool {
        send(.releaseReservation(reservation))
    }

    func preflight(_ reservation: TransactionApprovalReservation) async -> TransactionPreflightOutcome {
        guard reducer.isCurrent(reservation) else { return .invalidated }
        guard !Task.isCancelled else {
            cancelPreflight(reservation)
            return .invalidated
        }
        let resolution: PreflightResolution = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    cancelPreflight(reservation)
                    continuation.resume(returning: .init(attemptID: snapshot.attemptID, outcome: .invalidated))
                    return
                }
                guard let start = reducer.beginPreflight(reservation) else {
                    continuation.resume(returning: .init(attemptID: snapshot.attemptID, outcome: .invalidated))
                    return
                }
                cancelActiveRequest()
                let request = PreflightRequest(token: start.token, continuation: continuation)
                activeRequest = .preflight(request)
                onSnapshot(start.snapshot)
                guard !Task.isCancelled else {
                    cancelPreflight(reservation)
                    request.resolve(.init(attemptID: snapshot.attemptID, outcome: .invalidated))
                    return
                }
                guard isActive(request), reducer.isCurrent(start.token) else {
                    request.resolve(.init(attemptID: snapshot.attemptID, outcome: .invalidated))
                    return
                }
                runPreflight(request, transaction: start.snapshot.transaction)
            }
        } onCancel: {
            Task { @MainActor in self.cancelPreflight(reservation) }
        }
        guard !Task.isCancelled, resolution.attemptID == snapshot.attemptID else { return .invalidated }
        return resolution.outcome
    }

    @discardableResult
    func retryPreparation() -> Bool {
        send(.retryPreparation)
    }

    @discardableResult
    func apply(edits: Transaction.Edits) -> Bool {
        send(.applyEdits(edits))
    }

    func beginSliderInteraction() {
        send(.sliderInteractionBegan)
    }

    @discardableResult
    func setFeeForSpeed(value: Double) -> Bool {
        let previousTransaction = snapshot.transaction
        let effects = reducer.reduce(.setFeeForSpeed(value))
        let transaction = snapshot.transaction
        let didChangeFee = transaction.preparedFee != previousTransaction.preparedFee ||
            transaction.feeProvenance != previousTransaction.feeProvenance
        run(effects)
        return didChangeFee
    }

    @discardableResult
    func endSliderInteraction(cancelled: Bool = false) -> Bool {
        let hadPendingMutation = reducer.state.restartGate.isPending
        send(.sliderInteractionEnded(cancelled: cancelled))
        return hadPendingMutation
    }

    func invalidate() {
        send(.finish)
    }

    private func cancelPreflight(_ reservation: TransactionApprovalReservation) {
        guard reducer.state.preparation.isCurrent(
            attemptID: reservation.attemptID, transactionID: reservation.transactionID
        ), snapshot.phase == .reserved || snapshot.phase == .preflighting else { return }
        invalidate()
    }

    @discardableResult
    private func send(_ event: TransactionApprovalReducer.Event) -> Bool {
        let effects = reducer.reduce(event)
        run(effects)
        return !effects.isEmpty
    }

    private func run(_ effects: [TransactionApprovalReducer.Effect]) {
        for effect in effects {
            switch effect {
            case .cancelActiveRequest:
                cancelActiveRequest()
            case .clearActiveRequest(let token):
                clearActiveRequest(token)
            case .runPreparation(let token, let transaction, let forceGasCheck):
                runPreparation(token: token, transaction: transaction, forceGasCheck: forceGasCheck)
            case .snapshot(let snapshot):
                onSnapshot(snapshot)
            }
        }
    }

    private func runPreparation(
        token: TransactionApprovalRequestToken,
        transaction: Transaction,
        forceGasCheck: Bool
    ) {
        guard reducer.isCurrent(token) else { return }
        let request = PreparationRequest(token: token)
        activeRequest = .preparation(request)
        let stream = operations.prepare(transaction, forceGasCheck, reducer.state.network)
        request.task = Task { [weak self] in
            do {
                for try await event in stream {
                    try Task.checkCancellation()
                    guard let self else { return }
                    switch event {
                    case .transactionUpdated(let value):
                        send(.preparationUpdate(token, value))
                    case .feeEstimate(let estimate):
                        send(.preparationEstimate(token, estimate))
                    case .ready(let value):
                        send(.preparationResult(token, .success(value)))
                    }
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.send(.preparationResult(token, .failure(error as? TransactionPreparationFailure ?? .invalidTransaction)))
            }
            self?.clearActiveRequest(token)
        }
    }

    private func runPreflight(
        _ request: PreflightRequest,
        transaction: Transaction
    ) {
        let operation = operations.preflight
        let network = reducer.state.network
        request.task = Task { [weak self, weak request] in
            let result: TransactionFeePreflightResult
            do {
                try Task.checkCancellation()
                let fetched = try await operation(transaction, network)
                try Task.checkCancellation()
                result = fetched
            } catch {
                guard !Task.isCancelled else { return }
                result = .unavailable(transaction, GasService.Estimate(info: nil, nextBaseFee: nil))
            }
            guard let self, let request else { return }
            completePreflight(request, result: result)
        }
    }

    private func completePreflight(_ request: PreflightRequest, result: TransactionFeePreflightResult) {
        guard isActive(request) else { return }
        guard let completion = reducer.completePreflight(request.token, result: result) else {
            clearActiveRequest(request.token)
            return
        }
        let resolution = PreflightResolution(
            attemptID: completion.snapshot.attemptID,
            outcome: completion.outcome
        )
        onSnapshot(completion.snapshot)
        guard isActive(request) else { return }
        activeRequest = nil
        request.resolve(resolution)
    }

    private func isActive(_ request: PreflightRequest) -> Bool {
        guard case .preflight(let current) = activeRequest else { return false }
        return current === request
    }

    private func cancelActiveRequest() {
        let request = activeRequest
        activeRequest = nil
        request?.cancel(attemptID: snapshot.attemptID)
    }

    private func clearActiveRequest(_ token: TransactionApprovalRequestToken) {
        guard activeRequest?.token == token else { return }
        let request = activeRequest
        activeRequest = nil
        if case .preflight(let request) = request {
            request.resolve(.init(attemptID: snapshot.attemptID, outcome: .invalidated))
        }
    }

    isolated deinit {
        activeRequest?.cancel(attemptID: reducer.snapshot.attemptID)
    }
}
