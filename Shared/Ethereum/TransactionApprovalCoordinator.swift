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

struct TransactionApprovalReservation: Equatable, Sendable {
    let attemptID: Int
    let transactionID: UUID
}

enum TransactionPreflightOutcome: Sendable {
    case approved(Transaction)
    case reviewRequired
    case invalidated
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

@MainActor
final class TransactionApprovalCoordinator {
    private struct RequestToken: Equatable, Hashable, Sendable {
        enum Kind: Equatable, Hashable, Sendable {
            case preparation
            case preflight
        }

        let attemptID: Int
        let transactionID: UUID
        let kind: Kind
    }

    private struct State {
        var transaction: Transaction
        let network: EthereumNetwork
        var preparation = TransactionPreparationState()
        var hasPendingSliderPreparation = false
        var suggestedNonce: String?
        var verifiedFeeEstimate: GasService.Estimate?
        var gasSpeedConfiguration = GasSpeedConfiguration()
        var preparationForceGasCheck = false
        var isSliderInteractionActive = false
        var notice: TransactionReviewNotice?
    }

    private struct PreflightResolution: Sendable {
        let attemptID: Int
        let outcome: TransactionPreflightOutcome
    }

    private final class PreparationRequest {
        let token: RequestToken
        var task: Task<Void, Never>?

        init(token: RequestToken) {
            self.token = token
        }
    }

    private final class PreflightRequest {
        let token: RequestToken
        var task: Task<Void, Never>?
        private var continuation: CheckedContinuation<PreflightResolution, Never>?

        init(
            token: RequestToken,
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

        var token: RequestToken {
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

    private var state: State
    private let operations: TransactionApprovalOperations
    private var activeRequest: ActiveRequest?
    var onSnapshot: (TransactionApprovalSnapshot) -> Void

    init(
        transaction: Transaction,
        network: EthereumNetwork,
        operations: TransactionApprovalOperations = .live(),
        onSnapshot: @escaping (TransactionApprovalSnapshot) -> Void = { _ in }
    ) {
        state = State(transaction: transaction, network: network)
        self.operations = operations
        self.onSnapshot = onSnapshot
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

    private func isCurrent(
        _ token: RequestToken
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
        _ token: RequestToken
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

    private func isCurrent(_ reservation: TransactionApprovalReservation) -> Bool {
        state.preparation.phase == .reserved && state.preparation.isCurrent(
            attemptID: reservation.attemptID, transactionID: reservation.transactionID
        )
    }

    func startPreparation(forceGasCheck: Bool) {
        guard state.preparation.allowsMutation else { return }
        state.notice = nil
        state.hasPendingSliderPreparation = false
        state.isSliderInteractionActive = false
        state.verifiedFeeEstimate = nil
        state.preparationForceGasCheck = forceGasCheck
        let transaction = state.transaction
        let attemptID = state.preparation.beginPreparation(for: transaction.id)
        let token = RequestToken(attemptID: attemptID, transactionID: transaction.id, kind: .preparation)
        cancelActiveRequest()
        publishSnapshot()
        guard isCurrent(token) else { return }
        runPreparation(token: token, transaction: transaction, forceGasCheck: forceGasCheck)
    }

    func reserveForPreflight() -> TransactionApprovalReservation? {
        guard snapshot.canApprove,
            let attemptID = state.preparation.reserveForPreflight(for: state.transaction.id)
        else { return nil }
        let reservation = TransactionApprovalReservation(attemptID: attemptID, transactionID: state.transaction.id)
        cancelActiveRequest()
        publishSnapshot()
        return isCurrent(reservation) ? reservation : nil
    }

    @discardableResult
    func releaseReservation(_ reservation: TransactionApprovalReservation) -> Bool {
        guard isCurrent(reservation),
            state.preparation.restoreReady(
                attemptID: reservation.attemptID, transactionID: reservation.transactionID
            )
        else { return false }
        publishSnapshot()
        return true
    }

    func preflight(_ reservation: TransactionApprovalReservation) async -> TransactionPreflightOutcome {
        guard isCurrent(reservation) else { return .invalidated }
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
                guard isCurrent(reservation),
                    let attemptID = state.preparation.beginPreflight(for: state.transaction.id)
                else {
                    continuation.resume(returning: .init(attemptID: snapshot.attemptID, outcome: .invalidated))
                    return
                }
                state.notice = nil
                let transaction = state.transaction
                let token = RequestToken(attemptID: attemptID, transactionID: transaction.id, kind: .preflight)
                cancelActiveRequest()
                let request = PreflightRequest(token: token, continuation: continuation)
                activeRequest = .preflight(request)
                publishSnapshot()
                guard !Task.isCancelled else {
                    cancelPreflight(reservation)
                    request.resolve(.init(attemptID: snapshot.attemptID, outcome: .invalidated))
                    return
                }
                guard isActive(request), isCurrent(token) else {
                    request.resolve(.init(attemptID: snapshot.attemptID, outcome: .invalidated))
                    return
                }
                runPreflight(request, transaction: transaction)
            }
        } onCancel: {
            Task { @MainActor in self.cancelPreflight(reservation) }
        }
        guard !Task.isCancelled, resolution.attemptID == snapshot.attemptID else { return .invalidated }
        return resolution.outcome
    }

    @discardableResult
    func retryPreparation() -> Bool {
        guard snapshot.canRetryPreparation else { return false }
        let forceGasCheck: Bool
        if case .preparationFailed = state.notice {
            forceGasCheck = state.preparationForceGasCheck
        } else {
            forceGasCheck = false
        }
        startPreparation(forceGasCheck: forceGasCheck)
        return true
    }

    @discardableResult
    func apply(edits: Transaction.Edits) -> Bool {
        let previousTransaction = state.transaction
        guard snapshot.canEdit, state.transaction.apply(edits) else { return false }
        state.gasSpeedConfiguration.commitAppliedEdits(edits, from: previousTransaction, to: state.transaction)
        state.notice = nil
        state.hasPendingSliderPreparation = false
        state.isSliderInteractionActive = false
        state.preparation.beginEditing(state.transaction.id)
        cancelActiveRequest()
        publishSnapshot()
        return true
    }

    func beginSliderInteraction() {
        guard state.preparation.allowsMutation else { return }
        state.gasSpeedConfiguration.markGasSliderInteraction()
        state.isSliderInteractionActive = true
    }

    @discardableResult
    func setFeeForSpeed(value: Double) -> Bool {
        guard state.preparation.allowsMutation,
            state.transaction.feeBasisBaseFeePerGas != nil,
            let info = state.gasSpeedConfiguration.info
        else { return false }
        state.gasSpeedConfiguration.markGasSliderInteraction()
        let previousFee = state.transaction.preparedFee
        let previousProvenance = state.transaction.feeProvenance
        let previousPosition = state.gasSpeedConfiguration.sliderPosition(for: state.transaction)
        state.transaction.setFeeForSpeed(value: value, inRelationTo: info)
        state.gasSpeedConfiguration.recordSelectedSliderPosition(value, for: state.transaction)
        guard state.transaction.preparedFee != previousFee || state.transaction.feeProvenance != previousProvenance
        else {
            if state.gasSpeedConfiguration.sliderPosition(for: state.transaction) != previousPosition {
                publishSnapshot()
            }
            return false
        }
        state.gasSpeedConfiguration.markGasSliderFeeChange()
        guard state.isSliderInteractionActive else {
            startPreparation(forceGasCheck: false)
            return true
        }
        if !state.hasPendingSliderPreparation {
            state.hasPendingSliderPreparation = true
            state.notice = nil
            state.preparation.beginEditing(state.transaction.id)
            cancelActiveRequest()
        }
        publishSnapshot()
        return true
    }

    @discardableResult
    func endSliderInteraction(cancelled: Bool = false) -> Bool {
        state.isSliderInteractionActive = false
        let hadPendingMutation = state.hasPendingSliderPreparation
        state.hasPendingSliderPreparation = false
        let didInstallPendingQuote = state.gasSpeedConfiguration.endGasSliderInteraction(
            didChangeFee: !cancelled && hadPendingMutation
        )
        if hadPendingMutation, !cancelled, state.preparation.allowsMutation {
            startPreparation(forceGasCheck: false)
        } else if didInstallPendingQuote {
            publishSnapshot()
        }
        return hadPendingMutation
    }

    func invalidate() {
        state.notice = nil
        state.hasPendingSliderPreparation = false
        state.isSliderInteractionActive = false
        state.preparation.finish()
        cancelActiveRequest()
        publishSnapshot()
    }

    private func cancelPreflight(_ reservation: TransactionApprovalReservation) {
        guard
            state.preparation.isCurrent(
            attemptID: reservation.attemptID, transactionID: reservation.transactionID
        ), snapshot.phase == .reserved || snapshot.phase == .preflighting else { return }
        invalidate()
    }

    private func receivePreparationUpdate(_ transaction: Transaction, token: RequestToken) {
        guard acceptsPreparationUpdate(token), transaction.id == token.transactionID else { return }
        state.transaction = transaction
        state.suggestedNonce = state.suggestedNonce ?? transaction.decimalNonceString
        publishSnapshot()
    }

    private func receivePreparationEstimate(_ estimate: GasService.Estimate, token: RequestToken) {
        guard token.kind == .preparation, isCurrent(token) else { return }
        install(estimate)
        publishSnapshot()
    }

    private func receivePreparationResult(
        _ result: Result<Transaction, TransactionPreparationFailure>, token: RequestToken
    ) {
        guard token.kind == .preparation, isCurrent(token) else { return }
        switch result {
        case .success(let prepared):
            guard prepared.id == token.transactionID,
                state.preparation.markReady(attemptID: token.attemptID, transactionID: token.transactionID)
            else { return }
            state.suggestedNonce = state.suggestedNonce ?? prepared.decimalNonceString
        case .failure(let failure):
            guard state.preparation.markFailed(attemptID: token.attemptID, transactionID: token.transactionID) else {
                return
            }
            if state.verifiedFeeEstimate == nil {
                state.transaction.currentBaseFeePerGas = nil
                state.transaction.nextBaseFeePerGas = nil
            }
            state.notice = .preparationFailed(failure)
            clearActiveRequest(token)
        }
        publishSnapshot()
    }

    private func install(
        _ transaction: Transaction,
        estimate: GasService.Estimate
    ) {
        state.transaction = transaction
        state.suggestedNonce =
            state.suggestedNonce ?? transaction.decimalNonceString
        install(estimate)
    }

    private func install(_ estimate: GasService.Estimate) {
        state.verifiedFeeEstimate = estimate
        estimate.applyBaseFeeContext(to: &state.transaction)
        state.gasSpeedConfiguration.applyFetchedEstimate(estimate)
    }

    private func publishSnapshot() {
        if let priorityFee = state.gasSpeedConfiguration.speedPriorityFeePerGas(for: state.transaction) {
            state.gasSpeedConfiguration.installTransactionFallback(feePerGas: priorityFee)
        }
        state.gasSpeedConfiguration.synchronizeSelectedSliderPosition(with: state.transaction)
        onSnapshot(snapshot)
    }

    private func runPreparation(
        token: RequestToken,
        transaction: Transaction,
        forceGasCheck: Bool
    ) {
        guard isCurrent(token) else { return }
        let request = PreparationRequest(token: token)
        activeRequest = .preparation(request)
        let stream = operations.prepare(transaction, forceGasCheck, state.network)
        guard activeRequest?.token == token, isCurrent(token) else { return }
        request.task = Task { [weak self] in
            do {
                for try await event in stream {
                    try Task.checkCancellation()
                    guard let self else { return }
                    switch event {
                    case .transactionUpdated(let value):
                        receivePreparationUpdate(value, token: token)
                    case .feeEstimate(let estimate):
                        receivePreparationEstimate(estimate, token: token)
                    case .ready(let value):
                        receivePreparationResult(.success(value), token: token)
                    }
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.receivePreparationResult(
                    .failure(error as? TransactionPreparationFailure ?? .invalidTransaction), token: token)
            }
            self?.clearActiveRequest(token)
        }
    }

    private func runPreflight(
        _ request: PreflightRequest,
        transaction: Transaction
    ) {
        let operation = operations.preflight
        let network = state.network
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
        let token = request.token
        guard token.kind == .preflight, isCurrent(token) else {
            clearActiveRequest(token)
            return
        }
        let outcome: TransactionPreflightOutcome
        switch result {
        case .safe(let transaction, let estimate):
            guard transaction.id == token.transactionID else { clearActiveRequest(token); return }
            install(transaction, estimate: estimate)
            state.notice = nil
            state.hasPendingSliderPreparation = false
            state.preparation.finish()
            outcome = .approved(state.transaction)
        case .walletManagedUpdated(let transaction, let estimate):
            guard transaction.id == token.transactionID,
                state.preparation.returnToReview(
                    attemptID: token.attemptID, transactionID: token.transactionID
                )
            else { clearActiveRequest(token); return }
            install(transaction, estimate: estimate)
            state.notice = .feesUpdated
            outcome = .reviewRequired
        case .userControlledUnsafe(let transaction, let estimate):
            guard transaction.id == token.transactionID,
                state.preparation.beginUnsafeFeeEditing(
                    attemptID: token.attemptID, transactionID: token.transactionID
                )
            else { clearActiveRequest(token); return }
            install(transaction, estimate: estimate)
            state.notice = .unsafeFees
            outcome = .reviewRequired
        case .unavailable(let transaction, let estimate):
            guard transaction.id == token.transactionID,
                state.preparation.markFailed(
                    attemptID: token.attemptID, transactionID: token.transactionID
                )
            else { clearActiveRequest(token); return }
            install(transaction, estimate: estimate)
            state.notice = .feesUnavailable
            outcome = .reviewRequired
        }
        let resolution = PreflightResolution(attemptID: snapshot.attemptID, outcome: outcome)
        publishSnapshot()
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

    private func clearActiveRequest(_ token: RequestToken) {
        guard activeRequest?.token == token else { return }
        let request = activeRequest
        activeRequest = nil
        if case .preflight(let request) = request {
            request.resolve(.init(attemptID: snapshot.attemptID, outcome: .invalidated))
        }
    }

    isolated deinit {
        activeRequest?.cancel(attemptID: snapshot.attemptID)
    }
}
