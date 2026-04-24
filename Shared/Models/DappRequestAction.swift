// ∅ 2026 lil org

import Foundation
import WalletCore

enum DappRequestAction {
    case none
    case justShowApp
    case showMessage(message: String, subtitle: String, completion: (() -> Void)?)
    case switchAccount(SelectAccountAction)
    case selectAccount(SelectAccountAction)
    case approveMessage(SignMessageAction)
    case approveTransaction(SendTransactionAction)
    case addEthereumChain(AddEthereumChainAction)
}

struct SelectAccountAction {
    let peer: PeerMeta?
    let coinType: CoinType?
    var selectedAccounts: Set<SpecificWalletAccount>
    let initiallyConnectedProviders: Set<InpageProvider>
    var network: EthereumNetwork?
    let source: Source
    let completion: (EthereumNetwork?, [SpecificWalletAccount]?) -> Void
    
    enum Source {
        case walletConnect, safariExtension
    }
}

struct SignMessageAction {
    let provider: InpageProvider
    let subject: ApprovalSubject
    let walletId: String
    let account: Account
    let meta: String
    let peerMeta: PeerMeta
    private(set) var solanaClusterSelection: SolanaClusterSelection? = nil
    let completion: (Bool) -> Void
}

final class SolanaClusterSelection {
    var selectedCluster: Solana.Cluster?
    let suggestedCluster: Solana.Cluster?
    let clusters = Solana.Cluster.allCases

    var selectedClusterDescription: String? {
        guard let selectedCluster else { return nil }
        return description(for: selectedCluster)
    }

    func description(for cluster: Solana.Cluster) -> String {
        var components = [
            cluster.displayName,
            Solana.RPCConfiguration().endpoint(for: cluster).source.displayName,
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
    let provider: InpageProvider
    let transaction: Transaction
    let chain: EthereumNetwork
    let walletId: String
    let account: Account
    let peerMeta: PeerMeta
    let completion: (Transaction?) -> Void
}

struct AddEthereumChainAction {
    let chainToAdd: EthereumNetworkFromDapp
    let completion: (Bool) -> Void
}
