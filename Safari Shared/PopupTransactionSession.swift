// ∅ 2026 lil org

import Foundation

@MainActor
final class PopupTransactionSession {

    enum PreflightOutcome {
        case approved(Transaction)
        case reviewRequired
        case invalidated
    }

    private let coordinator: TransactionApprovalCoordinator
    private var gasSpeedConfiguration = GasSpeedConfiguration()
    private var authenticationToken: TransactionApprovalRequestToken?
    private var preflightContinuation: CheckedContinuation<PreflightOutcome, Never>?
    private(set) var activeAlert: TransactionApprovalAlertIntent?
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
        return commit(edits, previousTransaction: transaction)
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
            activeAlert = intent
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
