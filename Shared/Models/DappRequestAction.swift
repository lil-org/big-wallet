// ∅ 2026 lil org

enum DappRequestAction {
    case switchAccount(SelectAccountAction)
    case selectAccount(SelectAccountAction)
    case approveMessage(SignMessageAction)
    case approveTransaction(SendTransactionAction)
    case addEthereumChain(AddEthereumChainAction)
}

enum DappRequestPreparation {
    case response(ResponseToExtension)
    case approval(DappRequestAction)
}

struct PreparedBroadcast {
    let recoveryResponse: ResponseToExtension
    let send: () async -> ResponseToExtension
}

enum DappExecutionResult {
    case response(ResponseToExtension)
    case broadcast(PreparedBroadcast)
}

struct SelectAccountAction {
    let coinType: WalletCoin?
    var selectedAccounts: Set<SpecificWalletAccount>
    let initiallyConnectedProviders: Set<InpageProvider>
    let network: EthereumNetwork?
    let resolve: (EthereumNetwork?, [SpecificWalletAccount]?) async -> ResponseToExtension

    var canSelectEthereumNetwork: Bool {
        if let coinType {
            return coinType == .ethereum
        }

        return initiallyConnectedProviders.contains(.ethereum) ||
            selectedAccounts.contains { $0.account.coin == .ethereum }
    }

    func canSubmitSelection(network: EthereumNetwork?) -> Bool {
        guard !selectedAccounts.isEmpty else { return false }
        let needsEthereumNetwork = selectedAccounts.contains { $0.account.coin == .ethereum }
        return !needsEthereumNetwork || network != nil
    }
}

struct SignMessageAction {
    let subject: ApprovalSubject
    let walletId: String
    let account: WalletAccount
    let meta: String
    private(set) var solanaClusterSelection: SolanaClusterSelection? = nil
    let resolve: (Bool) async -> DappExecutionResult

    init(
        subject: ApprovalSubject,
        walletId: String,
        account: WalletAccount,
        meta: String,
        solanaClusterSelection: SolanaClusterSelection? = nil,
        resolve: @escaping (Bool) async -> ResponseToExtension
    ) {
        self.init(
            subject: subject,
            walletId: walletId,
            account: account,
            meta: meta,
            solanaClusterSelection: solanaClusterSelection,
            resolve: { approved -> DappExecutionResult in
                return .response(await resolve(approved))
            }
        )
    }

    init(
        subject: ApprovalSubject,
        walletId: String,
        account: WalletAccount,
        meta: String,
        solanaClusterSelection: SolanaClusterSelection? = nil,
        resolve: @escaping (Bool) async -> DappExecutionResult
    ) {
        self.subject = subject
        self.walletId = walletId
        self.account = account
        self.meta = meta
        self.solanaClusterSelection = solanaClusterSelection
        self.resolve = resolve
    }
}

final class SolanaClusterSelection {
    var selectedCluster: Solana.Cluster?
    let suggestedCluster: Solana.Cluster?
    let clusters = Solana.Cluster.allCases

    func description(for cluster: Solana.Cluster) -> String {
        var components = [
            cluster.displayName,
            cluster.rpcSource.displayName,
        ]
        if cluster == suggestedCluster {
            components.append(Strings.suggestedByWebsite)
        }
        return components.joined(separator: " - ")
    }

    init(selectedCluster: Solana.Cluster? = nil, suggestedCluster: Solana.Cluster? = nil) {
        self.selectedCluster = selectedCluster
        self.suggestedCluster = suggestedCluster
    }
}

struct SendTransactionAction {
    let transaction: Transaction
    let resolvedNetwork: ResolvedEthereumNetwork
    let walletId: String
    let account: WalletAccount
    let resolve: (Transaction?) async -> DappExecutionResult

    init(
        transaction: Transaction,
        resolvedNetwork: ResolvedEthereumNetwork,
        walletId: String,
        account: WalletAccount,
        resolve: @escaping (Transaction?) async -> ResponseToExtension
    ) {
        self.init(
            transaction: transaction,
            resolvedNetwork: resolvedNetwork,
            walletId: walletId,
            account: account,
            resolve: { transaction -> DappExecutionResult in
                return .response(await resolve(transaction))
            }
        )
    }

    init(
        transaction: Transaction,
        resolvedNetwork: ResolvedEthereumNetwork,
        walletId: String,
        account: WalletAccount,
        resolve: @escaping (Transaction?) async -> DappExecutionResult
    ) {
        self.transaction = transaction
        self.resolvedNetwork = resolvedNetwork
        self.walletId = walletId
        self.account = account
        self.resolve = resolve
    }

    var chain: EthereumNetwork {
        return resolvedNetwork.network
    }

    var rpcSource: RPCSource {
        return resolvedNetwork.source
    }
}

struct AddEthereumChainAction {
    let chainToAdd: EthereumNetworkFromDapp
    let resolve: (Bool) async -> ResponseToExtension
}
