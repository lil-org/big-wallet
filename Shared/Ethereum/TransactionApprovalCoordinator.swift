// ∅ 2026 lil org

import Foundation

struct TransactionPreparationState: Equatable {

    enum Phase: String, Equatable, Encodable {
        case idle
        case preparing
        case ready
        case failed
        case editing
        case authenticating
        case preflighting
        case reviewingFees
        case finished
    }

    private(set) var phase: Phase = .idle
    private(set) var attemptID = 0
    private(set) var transactionID: UUID?

    var allowsMutation: Bool {
        switch phase {
        case .authenticating, .preflighting, .reviewingFees, .finished:
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
    mutating func beginAuthentication(for transactionID: UUID) -> Int? {
        guard phase == .ready,
              transactionID == self.transactionID else {
            return nil
        }
        attemptID &+= 1
        phase = .authenticating
        return attemptID
    }

    @discardableResult
    mutating func beginPreflight(for transactionID: UUID) -> Int? {
        guard (phase == .ready || phase == .authenticating),
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
        guard phase == .authenticating,
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
    mutating func beginFeeReview(
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
        phase = .reviewingFees
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

enum TransactionApprovalAuthenticationPolicy {
    case required
    case skipped
}

struct TransactionApprovalRequestToken: Equatable, Hashable {

    enum Kind: Equatable, Hashable {
        case preparation
        case authentication
        case preflight
    }

    let attemptID: Int
    let transactionID: UUID
    let kind: Kind

}

struct TransactionApprovalAlertToken: Equatable, Hashable {

    enum Kind: Equatable, Hashable {
        case preparationFailure
        case feesUpdated
        case unsafeFees
        case unavailableFees
    }

    let attemptID: Int
    let transactionID: UUID
    let kind: Kind

}

struct TransactionApprovalAlertIntent: Equatable {

    enum Kind: Equatable {
        case preparationFailure(
            TransactionPreparationFailure,
            forceGasCheck: Bool
        )
        case feesUpdated
        case unsafeFees
        case unavailableFees

        var tokenKind: TransactionApprovalAlertToken.Kind {
            switch self {
            case .preparationFailure:
                return .preparationFailure
            case .feesUpdated:
                return .feesUpdated
            case .unsafeFees:
                return .unsafeFees
            case .unavailableFees:
                return .unavailableFees
            }
        }
    }

    let token: TransactionApprovalAlertToken
    let kind: Kind

    init(
        attemptID: Int,
        transactionID: UUID,
        kind: Kind
    ) {
        token = TransactionApprovalAlertToken(
            attemptID: attemptID,
            transactionID: transactionID,
            kind: kind.tokenKind
        )
        self.kind = kind
    }

}

enum TransactionApprovalAlertAction: String, Codable {
    case acknowledge
    case retry
    case edit
    case cancel
}

struct TransactionApprovalAlertPresentation {

    struct Action {
        let title: String
        let action: TransactionApprovalAlertAction
    }

    let title: String
    let message: String?
    let primaryAction: Action
    let secondaryAction: Action?

    var actions: [Action] {
        guard let secondaryAction else { return [primaryAction] }
        return [primaryAction, secondaryAction]
    }

}

extension TransactionApprovalAlertIntent {

    var presentation: TransactionApprovalAlertPresentation {
        switch kind {
        case .preparationFailure(.unsafeFees, _), .unsafeFees:
            return TransactionApprovalAlertPresentation(
                title: Strings.unsafeFees,
                message: Strings.unsafeFeesEdit,
                primaryAction: .init(
                    title: Strings.editFees,
                    action: .edit
                ),
                secondaryAction: .init(
                    title: Strings.cancel,
                    action: .cancel
                )
            )
        case .preparationFailure(_, _), .unavailableFees:
            return TransactionApprovalAlertPresentation(
                title: Strings.somethingWentWrong,
                message: nil,
                primaryAction: .init(
                    title: Strings.tryAgain,
                    action: .retry
                ),
                secondaryAction: .init(
                    title: Strings.cancel,
                    action: .cancel
                )
            )
        case .feesUpdated:
            return TransactionApprovalAlertPresentation(
                title: Strings.feesUpdated,
                message: Strings.feesUpdatedReview,
                primaryAction: .init(
                    title: Strings.ok,
                    action: .acknowledge
                ),
                secondaryAction: nil
            )
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
}

enum TransactionApprovalOutput {
    case snapshot(TransactionApprovalSnapshot)
    case authenticationRequest(TransactionApprovalRequestToken)
    case alert(TransactionApprovalAlertIntent)
    case editorRequest
    case completion(Transaction?)
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
        let authenticationPolicy: TransactionApprovalAuthenticationPolicy
        var preparation = TransactionPreparationState()
        var restartGate = TransactionPreparationRestartGate()
        var suggestedNonce: String?
        var verifiedFeeEstimate: GasService.Estimate?
        var gasSpeedConfiguration = GasSpeedConfiguration()
        var preparationForceGasCheck = false
        var isSliderInteractionActive = false
        var activeAlert: TransactionApprovalAlertIntent?
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
        case approve
        case authenticationResult(
            TransactionApprovalRequestToken,
            succeeded: Bool
        )
        case preflightResult(
            TransactionApprovalRequestToken,
            TransactionFeePreflightResult
        )
        case alertAction(
            TransactionApprovalAlertToken,
            TransactionApprovalAlertAction
        )
        case applyEdits(Transaction.Edits)
        case sliderInteractionBegan
        case setFeeForSpeed(Double)
        case sliderInteractionEnded(cancelled: Bool)
        case finish(Transaction?)
    }

    enum Effect {
        case cancelActiveRequest
        case clearActiveRequest(TransactionApprovalRequestToken)
        case runPreparation(
            TransactionApprovalRequestToken,
            Transaction,
            forceGasCheck: Bool
        )
        case runPreflight(
            TransactionApprovalRequestToken,
            Transaction
        )
        case snapshot(TransactionApprovalSnapshot)
        case authenticationRequest(TransactionApprovalRequestToken)
        case alert(TransactionApprovalAlertIntent)
        case editorRequest
        case completion(Transaction?)
    }

    private(set) var state: State

    init(
        transaction: Transaction,
        network: EthereumNetwork,
        authenticationPolicy: TransactionApprovalAuthenticationPolicy
    ) {
        state = State(
            transaction: transaction,
            network: network,
            authenticationPolicy: authenticationPolicy
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
            canEdit: canEdit
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
        case .authentication:
            return state.preparation.phase == .authenticating
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

    func isCurrent(
        _ token: TransactionApprovalAlertToken
    ) -> Bool {
        guard state.activeAlert?.token == token,
              state.preparation.isCurrent(
                attemptID: token.attemptID,
                transactionID: token.transactionID
              ) else {
            return false
        }
        switch token.kind {
        case .preparationFailure, .unavailableFees:
            return state.preparation.phase == .failed
        case .feesUpdated:
            return state.preparation.phase == .reviewingFees
        case .unsafeFees:
            return state.preparation.phase == .editing
        }
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
        case .approve:
            return approve()
        case .authenticationResult(let token, let succeeded):
            return receiveAuthenticationResult(
                token,
                succeeded: succeeded
            )
        case .preflightResult(let token, let result):
            return receivePreflightResult(result, token: token)
        case .alertAction(let token, let action):
            return handleAlertAction(action, token: token)
        case .applyEdits(let edits):
            return apply(edits)
        case .sliderInteractionBegan:
            return beginSliderInteraction()
        case .setFeeForSpeed(let value):
            return setFeeForSpeed(value: value)
        case .sliderInteractionEnded(let cancelled):
            return endSliderInteraction(cancelled: cancelled)
        case .finish(let transaction):
            return finish(with: transaction)
        }
    }

    private mutating func startPreparation(
        forceGasCheck: Bool
    ) -> [Effect] {
        guard state.preparation.phase != .finished else { return [] }
        state.activeAlert = nil
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
            let alert = TransactionApprovalAlertIntent(
                attemptID: token.attemptID,
                transactionID: token.transactionID,
                kind: .preparationFailure(
                    failure,
                    forceGasCheck: state.preparationForceGasCheck
                )
            )
            state.activeAlert = alert
            return [
                .clearActiveRequest(token),
                snapshotEffect(),
                .alert(alert),
            ]
        }
    }

    private mutating func approve() -> [Effect] {
        let transaction = state.transaction
        guard state.preparation.canApprove(
            transactionID: transaction.id,
            transactionIsReady: transaction.isReadyForApproval(
                on: state.network
            )
        ) else {
            return []
        }
        switch state.authenticationPolicy {
        case .required:
            guard let attemptID = state.preparation.beginAuthentication(
                for: transaction.id
            ) else {
                return []
            }
            let token = TransactionApprovalRequestToken(
                attemptID: attemptID,
                transactionID: transaction.id,
                kind: .authentication
            )
            return [
                .cancelActiveRequest,
                snapshotEffect(),
                .authenticationRequest(token),
            ]
        case .skipped:
            return beginPreflight(for: transaction)
        }
    }

    private mutating func receiveAuthenticationResult(
        _ token: TransactionApprovalRequestToken,
        succeeded: Bool
    ) -> [Effect] {
        guard token.kind == .authentication, isCurrent(token) else {
            return []
        }
        guard succeeded else {
            guard state.preparation.restoreReady(
                attemptID: token.attemptID,
                transactionID: token.transactionID
            ) else {
                return []
            }
            return [snapshotEffect()]
        }
        return beginPreflight(for: state.transaction)
    }

    private mutating func beginPreflight(
        for transaction: Transaction
    ) -> [Effect] {
        guard let attemptID = state.preparation.beginPreflight(
            for: transaction.id
        ) else {
            return []
        }
        state.activeAlert = nil
        let token = TransactionApprovalRequestToken(
            attemptID: attemptID,
            transactionID: transaction.id,
            kind: .preflight
        )
        return [
            .cancelActiveRequest,
            snapshotEffect(),
            .runPreflight(token, transaction),
        ]
    }

    private mutating func receivePreflightResult(
        _ result: TransactionFeePreflightResult,
        token: TransactionApprovalRequestToken
    ) -> [Effect] {
        guard token.kind == .preflight, isCurrent(token) else {
            return []
        }
        switch result {
        case .safe(let transaction, let estimate):
            guard transaction.id == token.transactionID else { return [] }
            install(transaction, estimate: estimate)
            state.activeAlert = nil
            state.restartGate = TransactionPreparationRestartGate()
            state.preparation.finish()
            return [
                .clearActiveRequest(token),
                snapshotEffect(),
                .completion(state.transaction),
            ]
        case .walletManagedUpdated(let transaction, let estimate):
            guard transaction.id == token.transactionID,
                  state.preparation.beginFeeReview(
                    attemptID: token.attemptID,
                    transactionID: token.transactionID
                  ) else {
                return []
            }
            install(transaction, estimate: estimate)
            let alert = TransactionApprovalAlertIntent(
                attemptID: token.attemptID,
                transactionID: token.transactionID,
                kind: .feesUpdated
            )
            state.activeAlert = alert
            return [
                .clearActiveRequest(token),
                snapshotEffect(),
                .alert(alert),
            ]
        case .userControlledUnsafe(let transaction, let estimate):
            guard transaction.id == token.transactionID,
                  state.preparation.beginUnsafeFeeEditing(
                    attemptID: token.attemptID,
                    transactionID: token.transactionID
                  ) else {
                return []
            }
            install(transaction, estimate: estimate)
            let alert = TransactionApprovalAlertIntent(
                attemptID: state.preparation.attemptID,
                transactionID: transaction.id,
                kind: .unsafeFees
            )
            state.activeAlert = alert
            return [
                .clearActiveRequest(token),
                snapshotEffect(),
                .alert(alert),
            ]
        case .unavailable(let transaction, let estimate):
            guard transaction.id == token.transactionID,
                  state.preparation.markFailed(
                    attemptID: token.attemptID,
                    transactionID: token.transactionID
                  ) else {
                return []
            }
            install(transaction, estimate: estimate)
            let alert = TransactionApprovalAlertIntent(
                attemptID: token.attemptID,
                transactionID: token.transactionID,
                kind: .unavailableFees
            )
            state.activeAlert = alert
            return [
                .clearActiveRequest(token),
                snapshotEffect(),
                .alert(alert),
            ]
        }
    }

    private mutating func handleAlertAction(
        _ action: TransactionApprovalAlertAction,
        token: TransactionApprovalAlertToken
    ) -> [Effect] {
        guard isCurrent(token), let alert = state.activeAlert else {
            return []
        }
        switch (alert.kind, action) {
        case (.preparationFailure(let failure, _), .edit)
            where failure == .unsafeFees:
            state.activeAlert = nil
            return [
                snapshotEffect(),
                .editorRequest,
            ]
        case (.preparationFailure(let failure, let forceGasCheck), .retry)
            where failure != .unsafeFees:
            return startPreparation(forceGasCheck: forceGasCheck)
        case (.feesUpdated, .acknowledge):
            return startPreparation(forceGasCheck: false)
        case (.unsafeFees, .edit):
            state.activeAlert = nil
            return [
                snapshotEffect(),
                .editorRequest,
            ]
        case (.unavailableFees, .retry):
            return startPreparation(forceGasCheck: false)
        case (.preparationFailure, .cancel),
             (.unsafeFees, .cancel),
             (.unavailableFees, .cancel):
            state.activeAlert = nil
            return [snapshotEffect()]
        default:
            return []
        }
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
        state.activeAlert = nil
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
            state.activeAlert = nil
            return startPreparation(forceGasCheck: false)
        }

        var effects = [Effect]()
        if state.restartGate.recordMutation() {
            state.activeAlert = nil
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

    private mutating func finish(
        with transaction: Transaction?
    ) -> [Effect] {
        guard state.preparation.phase != .finished else { return [] }
        if let transaction {
            state.transaction = transaction
        }
        state.activeAlert = nil
        state.restartGate = TransactionPreparationRestartGate()
        state.isSliderInteractionActive = false
        state.preparation.finish()
        return [
            .cancelActiveRequest,
            snapshotEffect(),
            .completion(transaction),
        ]
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
        if let priorityFee = state.gasSpeedConfiguration.speedPriorityFeePerGas(for: state.transaction) {
            state.gasSpeedConfiguration.installTransactionFallback(feePerGas: priorityFee)
        }
        state.gasSpeedConfiguration.synchronizeSelectedSliderPosition(with: state.transaction)
        return .snapshot(snapshot)
    }

}

@MainActor
final class TransactionApprovalCoordinator {

    private final class ActiveRequest {
        let token: TransactionApprovalRequestToken
        var task: Task<Void, Never>?

        init(token: TransactionApprovalRequestToken) {
            self.token = token
        }
    }

    private var reducer: TransactionApprovalReducer
    private let operations: TransactionApprovalOperations
    private var activeRequest: ActiveRequest?
    var onOutput: (TransactionApprovalOutput) -> Void

    init(
        transaction: Transaction,
        network: EthereumNetwork,
        authenticationPolicy: TransactionApprovalAuthenticationPolicy,
        operations: TransactionApprovalOperations = .live(),
        onOutput: @escaping (TransactionApprovalOutput) -> Void = { _ in }
    ) {
        reducer = TransactionApprovalReducer(
            transaction: transaction,
            network: network,
            authenticationPolicy: authenticationPolicy
        )
        self.operations = operations
        self.onOutput = onOutput
    }

    var snapshot: TransactionApprovalSnapshot {
        reducer.snapshot
    }

    var activeAlert: TransactionApprovalAlertIntent? {
        reducer.state.activeAlert
    }

    func startPreparation(forceGasCheck: Bool) {
        send(.startPreparation(forceGasCheck: forceGasCheck))
    }

    @discardableResult
    func approve() -> Bool {
        return send(.approve)
    }

    func authenticationCompleted(
        token: TransactionApprovalRequestToken,
        succeeded: Bool
    ) {
        send(.authenticationResult(token, succeeded: succeeded))
    }

    func isCurrentAlert(
        _ token: TransactionApprovalAlertToken
    ) -> Bool {
        reducer.isCurrent(token)
    }

    func handleAlert(
        token: TransactionApprovalAlertToken,
        action: TransactionApprovalAlertAction
    ) {
        send(.alertAction(token, action))
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

    func cancel() {
        send(.finish(nil))
    }

    func invalidate() {
        run(reducer.reduce(.finish(nil)).filter { effect in
            if case .completion = effect { return false }
            return true
        })
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
            case .runPreparation(
                let token,
                let transaction,
                let forceGasCheck
            ):
                runPreparation(
                    token: token,
                    transaction: transaction,
                    forceGasCheck: forceGasCheck
                )
            case .runPreflight(let token, let transaction):
                runPreflight(token: token, transaction: transaction)
            case .snapshot(let snapshot):
                onOutput(.snapshot(snapshot))
            case .authenticationRequest(let token):
                onOutput(.authenticationRequest(token))
            case .alert(let alert):
                onOutput(.alert(alert))
            case .editorRequest:
                onOutput(.editorRequest)
            case .completion(let transaction):
                onOutput(.completion(transaction))
            }
        }
    }

    private func runPreparation(
        token: TransactionApprovalRequestToken,
        transaction: Transaction,
        forceGasCheck: Bool
    ) {
        guard reducer.isCurrent(token) else { return }
        let request = ActiveRequest(token: token)
        activeRequest = request
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
                self?.send(
                    .preparationResult(token, .failure(error as? TransactionPreparationFailure ?? .invalidTransaction)))
            }
            self?.clearActiveRequest(token)
        }
    }

    private func runPreflight(token: TransactionApprovalRequestToken, transaction: Transaction) {
        guard reducer.isCurrent(token) else { return }
        let request = ActiveRequest(token: token)
        activeRequest = request
        let operation = operations.preflight
        let network = reducer.state.network
        request.task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let result = try await operation(transaction, network)
                try Task.checkCancellation()
                self?.send(.preflightResult(token, result))
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.send(
                    .preflightResult(token, .unavailable(transaction, GasService.Estimate(info: nil, nextBaseFee: nil)))
                )
            }
            self?.clearActiveRequest(token)
        }
    }

    private func cancelActiveRequest() {
        let request = activeRequest
        activeRequest = nil
        request?.task?.cancel()
    }

    private func clearActiveRequest(_ token: TransactionApprovalRequestToken) {
        guard activeRequest?.token == token else { return }
        activeRequest = nil
    }

    isolated deinit {
        activeRequest?.task?.cancel()
    }
}
