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
        let nonce: BigUInt
        let gasLimit: BigUInt
        let fee: PreparedTransactionFee
        let feeProvenance: TransactionFeeProvenance
        let feeBasisBaseFeePerGas: BigUInt?
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
            self.nonce = nonce
            self.approvedAccount = approvedAccount
            self.gasLimit = gasLimit
            fee = preparedFee
            feeProvenance = transaction.feeProvenance
            feeBasisBaseFeePerGas = transaction.feeBasisBaseFeePerGas
            self.reviewedNetwork = networkIdentity
        }

        func applying(to action: SendTransactionAction) -> Transaction? {
            guard isApplicable(to: action) else { return nil }
            return applyingValidatedFields(to: action.transaction)
        }

        fileprivate func isApplicable(to action: SendTransactionAction) -> Bool {
            guard let currentNetwork = NetworkIdentity(action.resolvedNetwork),
                  reviewedNetwork == currentNetwork,
                  !gasLimit.isZero,
                  fee.isStructurallyValid,
                  feeBasisBaseFeePerGas.map(Transaction.isValidUInt256) != false else { return false }
            switch fee {
            case .legacy:
                guard feeProvenance.maxPriorityFeePerGas == nil,
                      feeProvenance.maxFeePerGas == nil else { return false }
            case .eip1559:
                guard feeProvenance.gasPrice == nil else { return false }
            }
            return true
        }

        fileprivate func applyingValidatedFields(to transaction: Transaction) -> Transaction {
            var result = transaction
            result.nonce = nonce.toHexString(withPrefix: true)
            result.gas = gasLimit.toHexString(withPrefix: true)
            result.replacePreparedFee(
                fee,
                provenance: feeProvenance
            )
            result.currentBaseFeePerGas = feeBasisBaseFeePerGas
            result.nextBaseFeePerGas = nil
            return result
        }
    }

    case accountSelection(AccountSelection)
    case message(MessageApproval)
    case transaction(TransactionExecution)
    case addEthereumChain

    var signingAccount: WalletAccountDescriptor? {
        switch self {
        case .message(let approval): return approval.approvedAccount
        case .transaction(let execution): return execution.approvedAccount
        case .accountSelection, .addEthereumChain: return nil
        }
    }
}

@MainActor
final class ApprovalReview {
    private enum State { case open, accepted, invalidated }

    let intent: BoundApprovalIntent
    private var state = State.open

    var binding: ExtensionBridge.RequestBinding { intent.binding }
    var request: SafariRequest { binding.request }
    var action: DappRequestAction { intent.action }

    init(intent: BoundApprovalIntent) {
        self.intent = intent
    }

    func renewed() -> ApprovalReview {
        ApprovalReview(intent: intent)
    }

    func invalidate() {
        if case .open = state { state = .invalidated }
    }

    func acceptAccounts(
        selection: DappApprovalDecision.AccountSelection,
        approvedAt: Date,
        nativeReceipt: ExtensionBridge.NativeDeliveryReceipt? = nil
    ) -> ReviewConsent? {
        switch action {
        case .selectAccount, .switchAccount:
            return accept(.accountSelection(selection), approvedAt: approvedAt, nativeReceipt: nativeReceipt)
        default:
            return nil
        }
    }

    func acceptMessage(
        cluster: Solana.Cluster?,
        approvedAt: Date,
        nativeReceipt: ExtensionBridge.NativeDeliveryReceipt? = nil
    ) -> ReviewConsent? {
        guard case .approveMessage(let action) = action else { return nil }
        return accept(.message(.init(
            approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account),
            solanaCluster: cluster
        )), approvedAt: approvedAt, nativeReceipt: nativeReceipt)
    }

    func acceptTransaction(
        execution: DappApprovalDecision.TransactionExecution,
        approvedAt: Date,
        nativeReceipt: ExtensionBridge.NativeDeliveryReceipt? = nil
    ) -> ReviewConsent? {
        guard case .approveTransaction = action else { return nil }
        return accept(.transaction(execution), approvedAt: approvedAt, nativeReceipt: nativeReceipt)
    }

    func acceptAddEthereumChain(
        approvedAt: Date,
        nativeReceipt: ExtensionBridge.NativeDeliveryReceipt? = nil
    ) -> ReviewConsent? {
        guard case .addEthereumChain = action else { return nil }
        return accept(.addEthereumChain, approvedAt: approvedAt, nativeReceipt: nativeReceipt)
    }

    private func accept(
        _ decision: DappApprovalDecision,
        approvedAt: Date,
        nativeReceipt: ExtensionBridge.NativeDeliveryReceipt?
    ) -> ReviewConsent? {
        guard case .open = state,
              approvedAt.timeIntervalSince1970.isFinite else { return nil }
        state = .accepted
        return ReviewConsent(intent: intent, decision: decision, approvedAt: approvedAt, nativeReceipt: nativeReceipt)
    }

}

fileprivate final class ConsentAuthorizationUse: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false

    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { return false }
        consumed = true
        return true
    }
}

struct ReviewConsent: Sendable {
    let intent: BoundApprovalIntent
    private let authorizationUse: ConsentAuthorizationUse
    let decision: DappApprovalDecision
    let approvedAt: Date
    let nativeReceipt: ExtensionBridge.NativeDeliveryReceipt?

    fileprivate init(
        intent: BoundApprovalIntent,
        decision: DappApprovalDecision,
        approvedAt: Date,
        nativeReceipt: ExtensionBridge.NativeDeliveryReceipt?
    ) {
        self.intent = intent
        authorizationUse = ConsentAuthorizationUse()
        self.decision = decision
        self.approvedAt = approvedAt
        self.nativeReceipt = nativeReceipt
    }

    var binding: ExtensionBridge.RequestBinding { intent.binding }
    var request: SafariRequest { binding.request }

    @MainActor
    func resolve(
        accounts: [SpecificWalletAccount]?,
        networkResolver: (String) -> EthereumNetwork?,
        transactionNetworkResolver: (Int) -> ResolvedEthereumNetwork? = {
            Nodes.resolution(chainId: $0).resolvedNetwork
        }
    ) -> Result<ResolvedDappApproval, DappApprovalValidator.Failure> {
        if let approvedAccount = intent.action.signingAccount {
            guard decision.signingAccount == approvedAccount,
                  accounts?.contains(where: {
                approvedAccount.matches(walletID: $0.walletId, account: $0.account)
            }) == true else { return .failure(.staleAccount) }
        }
        let transactionNetwork: ResolvedEthereumNetwork?
        if case .approveTransaction(let action) = intent.action {
            guard let current = transactionNetworkResolver(action.chain.chainId) else {
                return .failure(.staleTransaction)
            }
            transactionNetwork = current
        } else {
            transactionNetwork = nil
        }
        return DappApprovalValidator.resolve(
            action: intent.action, decision: decision, accounts: accounts,
            networkResolver: networkResolver, transactionNetwork: transactionNetwork
        ).map { approval in
            ResolvedDappApproval(
                binding: binding, approval: approval,
                nativeReceipt: nativeReceipt, approvedAt: approvedAt,
                authorizationUse: authorizationUse
            )
        }
    }

}

struct ResolvedDappApproval: Sendable {
    let binding: ExtensionBridge.RequestBinding
    let approval: DappApprovalValidator.Approval
    private let authorizationUse: ConsentAuthorizationUse
    let nativeReceipt: ExtensionBridge.NativeDeliveryReceipt?
    let approvedAt: Date

    var request: SafariRequest { binding.request }

    fileprivate init(
        binding: ExtensionBridge.RequestBinding,
        approval: DappApprovalValidator.Approval,
        nativeReceipt: ExtensionBridge.NativeDeliveryReceipt?,
        approvedAt: Date,
        authorizationUse: ConsentAuthorizationUse
    ) {
        self.binding = binding
        self.approval = approval
        self.authorizationUse = authorizationUse
        self.nativeReceipt = nativeReceipt
        self.approvedAt = approvedAt
    }

    func consumeAuthorization() -> Bool {
        authorizationUse.consume()
    }
}

enum DappApprovalValidator {

    struct Selection: Sendable {
        let accounts: [SpecificWalletAccount]
        let network: EthereumNetwork?
    }

    struct Approval: Sendable {
        enum Kind: Sendable {
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
        networkResolver: (String) -> EthereumNetwork?,
        transactionNetwork: ResolvedEthereumNetwork? = nil
    ) -> Result<Approval, Failure> {
        switch (action, decision) {
        case (.selectAccount(let action), .accountSelection(let selection)),
             (.switchAccount(let action), .accountSelection(let selection)):
            guard let accounts,
                  let resolved = resolveSelection(
                    action: action, selection: selection,
                    accounts: accounts, networkResolver: networkResolver
                  ) else { return .failure(.invalidDecision) }
            return .success(Approval(.accountSelection(action, resolved)))
        case (.approveMessage(let action), .message(let approval)):
            guard approval.approvedAccount.matches(walletID: action.walletId, account: action.account) else {
                return .failure(.staleAccount)
            }
            guard let payload = resolveMessagePayload(action.payload, cluster: approval.solanaCluster) else {
                return .failure(.invalidDecision)
            }
            return .success(Approval(.signing(approvedAccount: approval.approvedAccount, payload: payload)))
        case (.approveTransaction(let action), .transaction(let execution)):
            guard execution.approvedAccount.matches(walletID: action.walletId, account: action.account) else {
                return .failure(.staleAccount)
            }
            let currentNetwork = transactionNetwork ?? action.resolvedNetwork
            guard execution.isApplicable(to: action),
                  DappApprovalDecision.NetworkIdentity(currentNetwork) == execution.reviewedNetwork else {
                return .failure(.staleTransaction)
            }
            let transaction = execution.applyingValidatedFields(to: action.transaction)
            guard transaction.isReadyForApproval(on: currentNetwork.network) else {
                return .failure(.invalidDecision)
            }
            return .success(Approval(.signing(
                approvedAccount: execution.approvedAccount,
                payload: .ethereumTransaction(transaction, currentNetwork)
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
