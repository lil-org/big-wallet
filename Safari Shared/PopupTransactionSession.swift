// ∅ 2026 lil org

import Foundation

@MainActor
final class PopupTransactionSession {

    enum PreflightOutcome: Sendable {
        case approved(Transaction)
        case reviewRequired
        case invalidated
    }

    private let coordinator: TransactionApprovalCoordinator
    private var authenticationToken: TransactionApprovalRequestToken?
    private var preflightContinuation: CheckedContinuation<PreflightOutcome, Never>?
    var editorRequestToken = 0
    var balance: String?
    var onChange: () -> Void = {}

    init(
        action: SendTransactionAction,
        operations: TransactionApprovalOperations
    ) {
        coordinator = TransactionApprovalCoordinator(
            transaction: action.transaction,
            network: action.chain,
            authenticationPolicy: .required,
            operations: operations
        )
        coordinator.onOutput = { [weak self] output in
            guard let self else { return }
            receive(output)
        }
    }

    var snapshot: TransactionApprovalSnapshot {
        return coordinator.snapshot
    }

    var activeAlert: TransactionApprovalAlertIntent? {
        coordinator.activeAlert
    }

    var requiresUserCorrection: Bool {
        activeAlert != nil || snapshot.phase == .editing || snapshot.phase == .reviewingFees
    }

    var hasGasSpeedInfo: Bool {
        coordinator.hasGasSpeedInfo
    }

    var gasSliderPosition: Double {
        coordinator.gasSliderPosition
    }

    func start() {
        coordinator.startPreparation(forceGasCheck: false)
    }

    func invalidate() {
        authenticationToken = nil
        coordinator.invalidate()
        finishPreflight(with: .invalidated)
    }

    func beginApproval() -> TransactionApprovalRequestToken? {
        guard authenticationToken == nil,
              preflightContinuation == nil,
              coordinator.approve(),
              let token = authenticationToken else { return nil }
        return token
    }

    func finishAuthentication(
        token: TransactionApprovalRequestToken,
        succeeded: Bool
    ) async -> PreflightOutcome {
        guard authenticationToken == token,
              preflightContinuation == nil else { return .invalidated }
        defer {
            if authenticationToken == token {
                authenticationToken = nil
            }
        }
        guard succeeded else {
            coordinator.authenticationCompleted(token: token, succeeded: false)
            return .reviewRequired
        }
        let outcome = await withCheckedContinuation { continuation in
            preflightContinuation = continuation
            coordinator.authenticationCompleted(token: token, succeeded: true)
        }
        guard authenticationToken == token else { return .invalidated }
        return outcome
    }

    private func finishPreflight(with outcome: PreflightOutcome) {
        let continuation = preflightContinuation
        preflightContinuation = nil
        continuation?.resume(returning: outcome)
    }

    func setSpeed(
        _ payload: InternalSafariRequest.TransactionSpeedPayload
    ) {
        switch payload.interaction {
        case .ended:
            coordinator.setFeeForSpeed(value: payload.value)
            coordinator.endSliderInteraction()
        case .cancelled:
            coordinator.endSliderInteraction(cancelled: true)
        }
    }

    func applyEdits(
        _ payload: InternalSafariRequest.TransactionEditsPayload,
        chain: EthereumNetwork
    ) -> Bool {
        let transactionSnapshot = snapshot
        let transaction = transactionSnapshot.transaction
        let fields: Transaction.EditableFields
        let selectedSuggestedFee: PreparedTransactionFee?

        switch payload {
        case .suggested:
            guard let suggestedFee = transactionSnapshot.latestWalletSuggestedFee else {
                return false
            }
            selectedSuggestedFee = suggestedFee
            let nonce = transactionSnapshot.suggestedNonce ?? transaction.editableFields.nonce
            switch suggestedFee {
            case .legacy(let gasPrice):
                fields = Transaction.EditableFields(
                    nonce: nonce,
                    gasPriceGwei: Transaction.editableGwei(fromWei: gasPrice) ?? "",
                    maxPriorityFeePerGasGwei: "",
                    maxFeePerGasGwei: ""
                )
            case .eip1559(let priority, let maximum):
                fields = Transaction.EditableFields(
                    nonce: nonce,
                    gasPriceGwei: "",
                    maxPriorityFeePerGasGwei: Transaction.editableGwei(fromWei: priority) ?? "",
                    maxFeePerGasGwei: Transaction.editableGwei(fromWei: maximum) ?? ""
                )
            }
        case .custom(let custom):
            selectedSuggestedFee = nil
            fields = Transaction.EditableFields(
                nonce: custom.nonce,
                gasPriceGwei: custom.gasPriceGwei ?? "",
                maxPriorityFeePerGasGwei: custom.maxPriorityFeePerGasGwei ?? "",
                maxFeePerGasGwei: custom.maxFeePerGasGwei ?? ""
            )
        }
        guard let edits = transaction.edits(
            from: fields,
            on: chain,
            resettingFeeTo: selectedSuggestedFee
        ) else { return false }
        guard edits != Transaction.Edits() else { return true }
        return commit(edits)
    }

    @discardableResult
    func resolveAlert(
        action: TransactionApprovalAlertAction
    ) -> Bool {
        guard let activeAlert,
              activeAlert.presentation.actions.contains(where: {
                  $0.action == action
              }) else {
            return false
        }
        coordinator.handleAlert(token: activeAlert.token, action: action)
        return true
    }

    private func commit(_ edits: Transaction.Edits) -> Bool {
        guard snapshot.canEdit else { return false }
        guard coordinator.apply(edits: edits) else { return true }
        coordinator.startPreparation(forceGasCheck: true)
        return true
    }

    private func receive(_ output: TransactionApprovalOutput) {
        switch output {
        case .snapshot, .verifiedFeeEstimate:
            break
        case .alert:
            finishPreflight(with: .reviewRequired)
        case .editorRequest:
            editorRequestToken += 1
        case .authenticationRequest(let token):
            if snapshot.phase == .authenticating {
                authenticationToken = token
            }
            return
        case .completion(let transaction):
            finishPreflight(with: transaction.map(PreflightOutcome.approved) ?? .invalidated)
            return
        }
        onChange()
    }

}
