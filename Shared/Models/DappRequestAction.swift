// ∅ 2026 lil org

import Foundation

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
    let selectedAccounts: Set<SpecificWalletAccount>
    let initiallyConnectedProviders: Set<InpageProvider>
    let network: EthereumNetwork?

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
    enum Payload {
        case ethereumMessage(Data)
        case ethereumPersonalMessage(Data)
        case ethereumTypedData(String)
        case solanaMessage(Data)
        case solanaTransaction(SolanaPreparedTransactionMessage)
        case solanaTransactions([SolanaPreparedTransactionMessage])
        case solanaLegacyBroadcast(
            Solana.PreparedLegacySignAndSendTransaction,
            Solana.PreparedSendOptions
        )
        case solanaSerializedBroadcast(
            Solana.PreparedSerializedTransaction,
            Solana.PreparedSendOptions
        )
    }

    let subject: ApprovalSubject
    let walletId: String
    let account: WalletAccount
    let meta: String
    let payload: Payload

    var solanaClusterOptions: SolanaClusterOptions? {
        switch payload {
        case .solanaLegacyBroadcast(_, let options),
             .solanaSerializedBroadcast(_, let options):
            return SolanaClusterOptions(suggestedCluster: options.clusterHint)
        case .ethereumMessage, .ethereumPersonalMessage, .ethereumTypedData,
             .solanaMessage, .solanaTransaction, .solanaTransactions:
            return nil
        }
    }
}

struct SolanaClusterOptions {
    let suggestedCluster: Solana.Cluster?
    var clusters: [Solana.Cluster] { Solana.Cluster.allCases }

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
}

struct SendTransactionAction {
    let transaction: Transaction
    let resolvedNetwork: ResolvedEthereumNetwork
    let walletId: String
    let account: WalletAccount

    var chain: EthereumNetwork {
        return resolvedNetwork.network
    }

    var rpcSource: RPCSource {
        return resolvedNetwork.source
    }
}

struct AddEthereumChainAction {
    let chainToAdd: EthereumNetworkFromDapp
}
