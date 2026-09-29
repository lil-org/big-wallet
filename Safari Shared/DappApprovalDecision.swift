// ∅ 2026 lil org

import Foundation

enum DappApprovalDecision: Equatable, Sendable {

    struct AccountSelection: Equatable, Sendable {
        let accounts: [WalletAccountDescriptor]
        let ethereumChainID: String?

        init(accounts: [WalletAccountDescriptor], ethereumChainID: String?) {
            self.accounts = accounts
            self.ethereumChainID = ethereumChainID
        }
    }

    struct MessageApproval: Equatable, Sendable {
        let approvedAccount: WalletAccountDescriptor
        let solanaCluster: Solana.Cluster?

        init(approvedAccount: WalletAccountDescriptor, solanaCluster: Solana.Cluster?) {
            self.approvedAccount = approvedAccount
            self.solanaCluster = solanaCluster
        }
    }

    enum TransactionFee: Equatable, Sendable {
        case legacy(gasPrice: String)
        case eip1559(maxPriorityFeePerGas: String, maxFeePerGas: String)
    }

    struct NetworkIdentity: Equatable, Sendable {

        enum Source: String, Equatable, Sendable {
            case alchemy, fallback, custom

            init(_ source: RPCSource) {
                switch source {
                case .alchemy:
                    self = .alchemy
                case .fallback:
                    self = .fallback
                case .custom:
                    self = .custom
                }
            }
        }

        let chainID: Int
        let source: Source
        let canonicalRPCURL: String
        let allowsAlchemyAuthorization: Bool

        init?(_ network: ResolvedEthereumNetwork) {
            guard network.network.chainId > 0,
                  let canonicalRPCURL = Self.canonicalRPCURL(
                    network.rpcURL
                  ) else { return nil }
            chainID = network.network.chainId
            source = .init(network.source)
            self.canonicalRPCURL = canonicalRPCURL
            allowsAlchemyAuthorization = network.allowsAlchemyAuthorization
        }

        private static func canonicalRPCURL(_ url: URL) -> String? {
            guard var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ), let scheme = components.scheme?.lowercased(),
               let host = components.host?.lowercased(),
               !scheme.isEmpty,
               !host.isEmpty else { return nil }
            components.scheme = scheme
            components.host = host
            if (scheme == "http" && components.port == 80)
                || (scheme == "https" && components.port == 443) {
                components.port = nil
            }
            components.fragment = nil
            if components.percentEncodedPath.isEmpty {
                components.percentEncodedPath = "/"
            }
            return components.string
        }
    }

    struct TransactionExecution: Equatable, Sendable {
        let approvedAccount: WalletAccountDescriptor
        let nonce: String
        let gasLimit: String
        let fee: TransactionFee
        let feeProvenance: TransactionFeeProvenance
        let feeBasisBaseFeePerGas: String?
        let reviewedNetwork: NetworkIdentity

        init?(
            _ transaction: Transaction,
            reviewedNetwork: ResolvedEthereumNetwork,
            approvedAccount: WalletAccountDescriptor
        ) {
            guard let nonce = transaction.nonce.flatMap({
                      EthereumQuantity.parseUInt256($0, allowPrefixless: true)
                  }),
                  let gasLimit = transaction.gas.flatMap({
                      EthereumQuantity.parseUInt256($0, allowPrefixless: true)
                  }),
                  let preparedFee = transaction.preparedFee,
                  let networkIdentity = NetworkIdentity(reviewedNetwork) else {
                return nil
            }
            self.nonce = nonce.toHexString(withPrefix: true)
            self.approvedAccount = approvedAccount
            self.gasLimit = gasLimit.toHexString(withPrefix: true)
            switch preparedFee {
            case .legacy(let gasPrice):
                fee = .legacy(gasPrice: gasPrice.toHexString(withPrefix: true))
            case .eip1559(let priority, let maximum):
                fee = .eip1559(
                    maxPriorityFeePerGas: priority.toHexString(withPrefix: true),
                    maxFeePerGas: maximum.toHexString(withPrefix: true)
                )
            }
            feeProvenance = transaction.feeProvenance
            feeBasisBaseFeePerGas = transaction.feeBasisBaseFeePerGas?
                .toHexString(withPrefix: true)
            self.reviewedNetwork = networkIdentity
        }

        func applying(to action: SendTransactionAction) -> Transaction? {
            guard let currentNetwork = NetworkIdentity(action.resolvedNetwork),
                  reviewedNetwork == currentNetwork else { return nil }
            return applyingTransactionFields(to: action.transaction)
        }

        private func applyingTransactionFields(
            to transaction: Transaction
        ) -> Transaction? {
            guard Self.uint256(nonce) != nil,
                  let gasLimitValue = Self.uint256(gasLimit),
                  !gasLimitValue.isZero else { return nil }
            let preparedFee: PreparedTransactionFee
            switch fee {
            case .legacy(let gasPrice):
                guard let value = Self.uint256(gasPrice),
                      feeProvenance.maxPriorityFeePerGas == nil,
                      feeProvenance.maxFeePerGas == nil else { return nil }
                preparedFee = .legacy(gasPrice: value)
            case .eip1559(let priority, let maximum):
                guard let priorityValue = Self.uint256(priority),
                      let maximumValue = Self.uint256(maximum),
                      maximumValue >= priorityValue,
                      feeProvenance.gasPrice == nil else { return nil }
                preparedFee = .eip1559(
                    maxPriorityFeePerGas: priorityValue,
                    maxFeePerGas: maximumValue
                )
            }
            guard preparedFee.isStructurallyValid else { return nil }
            let feeBasis: BigUInt?
            if let rawFeeBasis = feeBasisBaseFeePerGas {
                guard let value = Self.uint256(rawFeeBasis) else { return nil }
                feeBasis = value
            } else {
                feeBasis = nil
            }
            var result = transaction
            result.nonce = nonce
            result.gas = gasLimit
            result.replacePreparedFee(
                preparedFee,
                provenance: feeProvenance
            )
            result.currentBaseFeePerGas = feeBasis
            result.nextBaseFeePerGas = nil
            return result
        }

        private static func uint256(_ value: String) -> BigUInt? {
            guard value.count <= 66 else { return nil }
            return EthereumQuantity.parseUInt256(value, allowPrefixless: true)
        }
    }

    case accountSelection(AccountSelection)
    case message(MessageApproval)
    case transaction(TransactionExecution)
    case addEthereumChain
}

enum DappApprovalValidator {

    struct Selection {
        let accounts: [SpecificWalletAccount]
        let network: EthereumNetwork?
    }

    struct Approval {
        enum Kind {
            case accountSelection(SelectAccountAction, Selection)
            case signing(
                approvedAccount: WalletAccountDescriptor,
                payload: ApprovedWalletSigningOperation.Payload
            )
            case addEthereumChain(AddEthereumChainAction)
        }

        let kind: Kind

        fileprivate init(_ kind: Kind) {
            self.kind = kind
        }

        var signingAccount: WalletAccountDescriptor? {
            switch kind {
            case .signing(let approvedAccount, _):
                return approvedAccount
            case .accountSelection, .addEthereumChain:
                return nil
            }
        }
    }

    enum Failure: Error {
        case invalidDecision
        case staleTransaction
        case staleAccount
    }

    static func resolve(
        action: DappRequestAction,
        decision: DappApprovalDecision,
        accounts: [SpecificWalletAccount]?,
        networkResolver: (String) -> EthereumNetwork?
    ) -> Result<Approval, Failure> {
        switch (action, decision) {
        case (.selectAccount(let action), .accountSelection(let selection)),
             (.switchAccount(let action), .accountSelection(let selection)):
            guard let accounts,
                  let resolved = resolveSelection(
                    action: action,
                    selection: selection,
                    accounts: accounts,
                    networkResolver: networkResolver
                  ) else { return .failure(.invalidDecision) }
            return .success(Approval(.accountSelection(action, resolved)))
        case (.approveMessage(let action), .message(let approval)):
            guard approval.approvedAccount.matches(walletID: action.walletId, account: action.account) else {
                return .failure(.staleAccount)
            }
            guard let payload = resolveMessagePayload(
                action.payload,
                cluster: approval.solanaCluster
            ) else {
                return .failure(.invalidDecision)
            }
            return .success(Approval(.signing(
                approvedAccount: approval.approvedAccount,
                payload: payload
            )))
        case (.approveTransaction(let action), .transaction(let execution)):
            guard execution.approvedAccount.matches(walletID: action.walletId, account: action.account) else {
                return .failure(.staleAccount)
            }
            guard let transaction = execution.applying(to: action) else {
                return .failure(.staleTransaction)
            }
            guard transaction.isReadyForApproval(on: action.chain) else {
                return .failure(.invalidDecision)
            }
            return .success(Approval(.signing(
                approvedAccount: execution.approvedAccount,
                payload: .ethereumTransaction(transaction, action.resolvedNetwork)
            )))
        case (.addEthereumChain(let action), .addEthereumChain):
            return .success(Approval(.addEthereumChain(action)))
        default:
            return .failure(.invalidDecision)
        }
    }

    private static func resolveMessagePayload(
        _ payload: SignMessageAction.Payload,
        cluster: Solana.Cluster?
    ) -> ApprovedWalletSigningOperation.Payload? {
        switch (payload, cluster) {
        case (.solanaLegacyBroadcast(let transaction, let options), let cluster?):
            return .solanaLegacyBroadcast(transaction, options, cluster)
        case (.solanaSerializedBroadcast(let transaction, let options), let cluster?):
            return .solanaSerializedBroadcast(transaction, options, cluster)
        case (.ethereumMessage(let data), nil):
            return .ethereumMessage(data)
        case (.ethereumPersonalMessage(let data), nil):
            return .ethereumPersonalMessage(data)
        case (.ethereumTypedData(let data), nil):
            return .ethereumTypedData(data)
        case (.solanaMessage(let data), nil):
            return .solanaMessage(data)
        case (.solanaTransaction(let transaction), nil):
            return .solanaTransaction(transaction)
        case (.solanaTransactions(let transactions), nil):
            return .solanaTransactions(transactions)
        default:
            return nil
        }
    }

    static func resolveSelection(
        action: SelectAccountAction,
        selection: DappApprovalDecision.AccountSelection,
        accounts: [SpecificWalletAccount],
        networkResolver: (String) -> EthereumNetwork?
    ) -> Selection? {
        var resolvedAccounts = [SpecificWalletAccount]()
        var selectedCoins = Set<WalletCoin>()
        for identity in selection.accounts {
            guard identity.isValid,
                  action.coinType == nil || action.coinType == identity.coin,
                  selectedCoins.insert(identity.coin).inserted else { return nil }
            let matches = accounts.filter {
                WalletAccountDescriptor(walletID: $0.walletId, account: $0.account) == identity
            }
            guard matches.count == 1 else { return nil }
            resolvedAccounts.append(matches[0])
        }
        let chainID = selection.ethereumChainID ?? action.network?.chainIdHexString
        let network = chainID.flatMap(networkResolver)
        if resolvedAccounts.isEmpty {
            guard !action.initiallyConnectedProviders.isEmpty else { return nil }
        } else {
            guard chainID == nil || network != nil,
                  !resolvedAccounts.contains(where: { $0.account.coin == .ethereum }) ||
                    network != nil else { return nil }
        }
        return Selection(accounts: resolvedAccounts, network: network)
    }
}
