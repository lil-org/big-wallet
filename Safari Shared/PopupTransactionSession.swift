// ∅ 2026 lil org

import Foundation

@MainActor
final class PopupTransactionSession {

    private let coordinator: TransactionApprovalCoordinator
    var balance: String?
    var onChange: () -> Void = {}

    init(
        action: SendTransactionAction,
        operations: TransactionApprovalOperations
    ) {
        coordinator = TransactionApprovalCoordinator(
            transaction: action.transaction,
            network: action.chain,
            operations: operations
        )
        coordinator.onSnapshot = { [weak self] _ in self?.onChange() }
    }

    var snapshot: TransactionApprovalSnapshot {
        return coordinator.snapshot
    }

    func start() {
        coordinator.startPreparation(forceGasCheck: false)
    }

    func invalidate() {
        coordinator.invalidate()
    }

    func reserveForPreflight() -> TransactionApprovalReservation? {
        coordinator.reserveForPreflight()
    }

    @discardableResult
    func releaseReservation(_ reservation: TransactionApprovalReservation) -> Bool {
        coordinator.releaseReservation(reservation)
    }

    func preflight(_ reservation: TransactionApprovalReservation) async -> TransactionPreflightOutcome {
        await coordinator.preflight(reservation)
    }

    func retryPreparation() -> Bool {
        coordinator.retryPreparation()
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

    private func commit(_ edits: Transaction.Edits) -> Bool {
        guard snapshot.canEdit else { return false }
        guard coordinator.apply(edits: edits) else { return true }
        coordinator.startPreparation(forceGasCheck: true)
        return true
    }

}
