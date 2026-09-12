// ∅ 2026 lil org

import Foundation

@MainActor
final class PopupTransactionSession {

    struct ActiveAlert {
        let intent: TransactionApprovalAlertIntent

        var token: TransactionApprovalAlertToken {
            return intent.token
        }

        var kind: TransactionApprovalAlertIntent.Kind {
            return intent.kind
        }

        var presentation: TransactionApprovalAlertPresentation {
            return intent.presentation
        }
    }

    private let coordinator: TransactionApprovalCoordinator
    private var gasSpeedConfiguration = GasSpeedConfiguration()
    private(set) var activeAlert: ActiveAlert?
    var editorRequestToken = 0
    var balance: String?
    var onOutput: (TransactionApprovalOutput) -> Void = { _ in }

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

    var hasGasSpeedInfo: Bool {
        return gasSpeedConfiguration.info != nil
    }

    func gasSliderPosition(for transaction: Transaction) -> Double {
        return gasSpeedConfiguration.sliderPosition(for: transaction)
    }

    func start() {
        coordinator.startPreparation(forceGasCheck: false)
    }

    func invalidate() {
        coordinator.invalidate()
    }

    @discardableResult
    func approve() -> Bool {
        return coordinator.approve()
    }

    func authenticationCompleted(
        token: TransactionApprovalRequestToken,
        succeeded: Bool
    ) {
        coordinator.authenticationCompleted(token: token, succeeded: succeeded)
    }

    func setSpeed(
        _ payload: InternalSafariRequest.TransactionSpeedPayload
    ) {
        func applyFee() -> Bool {
            guard snapshot.transaction.feeBasisBaseFeePerGas != nil,
                  let info = gasSpeedConfiguration.info else { return false }
            gasSpeedConfiguration.markGasSliderInteraction()
            let didChangeFee = coordinator.setFeeForSpeed(
                value: payload.value,
                inRelationTo: info
            )
            let transaction = snapshot.transaction
            gasSpeedConfiguration.recordSelectedSliderPosition(
                payload.value,
                for: transaction
            )
            if didChangeFee {
                gasSpeedConfiguration.markGasSliderFeeChange()
            }
            return didChangeFee
        }

        func closeInteraction(didChangeFee: Bool) {
            guard gasSpeedConfiguration.endGasSliderInteraction(
                didChangeFee: didChangeFee
            ) else { return }
            updateSpeedConfiguration(transaction: snapshot.transaction)
        }

        switch payload.interaction {
        case .ended:
            closeInteraction(didChangeFee: applyFee())
        case .cancelled:
            _ = coordinator.endSliderInteraction(cancelled: true)
            closeInteraction(didChangeFee: false)
        }
    }

    func applyEdits(
        _ payload: InternalSafariRequest.TransactionEditsPayload,
        chain: EthereumNetwork
    ) -> Bool {
        let transactionSnapshot = snapshot
        let transaction = transactionSnapshot.transaction
        let suggestedFee = transactionSnapshot.latestWalletSuggestedFee
        let fields = transaction.editableFields

        switch payload {
        case .suggested:
            guard let suggestedFee else { return false }
            return commit(
                Transaction.Edits(
                    preparedFee: suggestedFee,
                    source: .automatic,
                    replacementFeeProvenance: TransactionFeeProvenance(
                        source: .automatic,
                        for: suggestedFee
                    ),
                    restoresSuggestedFee: true,
                    nonce: transactionSnapshot.suggestedNonce.flatMap { UInt($0) }
                ),
                previousTransaction: transaction
            )
        case .custom(let custom):
            var nonceEdit: UInt?
            if custom.nonce != fields.nonce {
                guard let nonce = UInt(custom.nonce) else { return false }
                nonceEdit = nonce
            }
            var candidateFee: PreparedTransactionFee?
            var candidateProvenance = transaction.feeProvenance
            if transaction.usesEIP1559Fees {
                let priorityText = custom.maxPriorityFeePerGasGwei ?? ""
                let maximumText = custom.maxFeePerGasGwei ?? ""
                if priorityText != fields.maxPriorityFeePerGasGwei ||
                    maximumText != fields.maxFeePerGasGwei {
                    guard let priority = Transaction.exactFeeWei(fromGwei: priorityText),
                          let maximum = Transaction.exactFeeWei(fromGwei: maximumText)
                    else { return false }
                    let fee = PreparedTransactionFee.eip1559(
                        maxPriorityFeePerGas: priority,
                        maxFeePerGas: maximum
                    )
                    guard fee.isStructurallyValid,
                          transaction.feeBasisBaseFeePerGas.map({ maximum >= $0 }) != false
                    else { return false }
                    candidateFee = fee
                    let editsSliderFee =
                        candidateProvenance.maxPriorityFeePerGas == .slider ||
                        candidateProvenance.maxFeePerGas == .slider
                    if editsSliderFee || priorityText != fields.maxPriorityFeePerGasGwei {
                        candidateProvenance.maxPriorityFeePerGas = .manual
                    }
                    if editsSliderFee || maximumText != fields.maxFeePerGasGwei {
                        candidateProvenance.maxFeePerGas = .manual
                    }
                }
            } else {
                let gasPriceText = custom.gasPriceGwei ?? ""
                if gasPriceText != fields.gasPriceGwei {
                    guard let gasPrice = Transaction.exactFeeWei(fromGwei: gasPriceText),
                          Transaction.isValidGasPrice(gasPrice, on: chain),
                          transaction.feeBasisBaseFeePerGas.map({ gasPrice >= $0 }) != false
                    else { return false }
                    candidateFee = .legacy(gasPrice: gasPrice)
                    candidateProvenance = TransactionFeeProvenance(gasPrice: .manual)
                }
            }
            if let candidateFee {
                guard candidateFee.maximumNetworkFeeFitsUInt256(
                    gasLimit: transaction.gasLimitValue
                ) else { return false }
                return commit(
                    Transaction.Edits(
                        preparedFee: candidateFee,
                        source: .manual,
                        replacementFeeProvenance: candidateProvenance,
                        nonce: nonceEdit
                    ),
                    previousTransaction: transaction
                )
            }
            if let nonceEdit {
                return commit(
                    Transaction.Edits(nonce: nonceEdit),
                    previousTransaction: transaction
                )
            }
            return true
        }
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

    private func updateSpeedConfiguration(transaction: Transaction) {
        if let priorityFee = gasSpeedConfiguration.speedPriorityFeePerGas(for: transaction) {
            gasSpeedConfiguration.installTransactionFallback(feePerGas: priorityFee)
        }
        gasSpeedConfiguration.synchronizeSelectedSliderPosition(with: transaction)
    }

    private func commit(
        _ edits: Transaction.Edits,
        previousTransaction: Transaction
    ) -> Bool {
        guard snapshot.canEdit else { return false }
        guard coordinator.apply(edits: edits) else { return true }
        let updatedTransaction = snapshot.transaction
        gasSpeedConfiguration.commitAppliedEdits(
            edits,
            from: previousTransaction,
            to: updatedTransaction
        )
        coordinator.startPreparation(forceGasCheck: true)
        return true
    }

    private func receive(_ output: TransactionApprovalOutput) {
        switch output {
        case .snapshot(let snapshot):
            updateSpeedConfiguration(transaction: snapshot.transaction)
            if activeAlert.map({ coordinator.isCurrentAlert($0.token) == false }) == true {
                activeAlert = nil
            }
        case .verifiedFeeEstimate(let estimate):
            gasSpeedConfiguration.applyFetchedEstimate(estimate)
        case .alert(let intent):
            activeAlert = ActiveAlert(intent: intent)
        case .editorRequest:
            editorRequestToken += 1
        case .authenticationRequest, .completion:
            break
        }
        onOutput(output)
    }

}
