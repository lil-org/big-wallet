import WalletDomain

public extension EthereumTransactionPreparation {
    func makePreparationOperations() -> TransactionApprovalOperations {
        TransactionApprovalOperations(
            prepare: { transaction, forceGasCheck, network in
                prepareTransaction(transaction, forceGasCheck: forceGasCheck, network: network)
            },
            preflight: { transaction, network in
                try await preflightTransactionFee(transaction, network: network)
            }
        )
    }
}
