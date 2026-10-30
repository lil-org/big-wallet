import Foundation

public enum DappRequestAction: Sendable {
    case switchAccount(SelectAccountAction)
    case selectAccount(SelectAccountAction)
    case approveMessage(SignMessageAction)
    case approveTransaction(SendTransactionAction)
    case addEthereumChain(AddEthereumChainAction)

    public var signingAccount: WalletAccountDescriptor? {
        switch self {
        case .approveMessage(let action):
            return WalletAccountDescriptor(walletID: action.walletId, account: action.account)
        case .approveTransaction(let action):
            return WalletAccountDescriptor(walletID: action.walletId, account: action.account)
        case .selectAccount, .switchAccount, .addEthereumChain:
            return nil
        }
    }
}


public struct SelectAccountAction: Sendable {
    public let coinType: WalletCoin?
    public let selectedAccounts: Set<SpecificWalletAccount>
    public let initiallyConnectedProviders: Set<InpageProvider>
    public let network: EthereumNetwork?

    public init(coinType: WalletCoin?, selectedAccounts: Set<SpecificWalletAccount>, initiallyConnectedProviders: Set<InpageProvider>, network: EthereumNetwork?) {
        self.coinType = coinType
        self.selectedAccounts = selectedAccounts
        self.initiallyConnectedProviders = initiallyConnectedProviders
        self.network = network
    }
}


public struct SigningReviewContent: Sendable {
    public let subject: ApprovalSubject
    public let meta: String
    public let payload: SignMessageAction.Payload

    public init(subject: ApprovalSubject, meta: String, payload: SignMessageAction.Payload) {
        self.subject = subject
        self.meta = meta
        self.payload = payload
    }
}


public enum SignaturePayload: Sendable {
    case ethereumPersonalMessage(Data)
    case ethereumTypedData(PreparedEthereumTypedData)
    case solanaMessage(Data)
    case solanaTransaction(SolanaPreparedTransactionMessage)
    case solanaTransactions([SolanaPreparedTransactionMessage])

    public var coin: WalletCoin {
        switch self {
        case .ethereumPersonalMessage, .ethereumTypedData:
            return .ethereum
        case .solanaMessage, .solanaTransaction, .solanaTransactions:
            return .solana
        }
    }
}


public struct SignMessageAction: Sendable {
    public enum Payload: Sendable {
        case signature(SignaturePayload)
        case solanaLegacyBroadcast(
            Solana.PreparedLegacySignAndSendTransaction,
            Solana.PreparedSendOptions
        )
        case solanaSerializedBroadcast(
            Solana.PreparedSerializedTransaction,
            Solana.PreparedSendOptions
        )

        public var coin: WalletCoin {
            switch self {
            case .signature(let payload):
                return payload.coin
            case .solanaLegacyBroadcast, .solanaSerializedBroadcast:
                return .solana
            }
        }
    }

    public let subject: ApprovalSubject
    public let walletId: String
    public let account: WalletAccount
    public let meta: String
    public let payload: Payload
    public let solanaEndpoints: [Solana.Cluster: SolanaRPCEndpoint]

    public var solanaClusterOptions: SolanaClusterOptions? {
        switch payload {
        case .solanaLegacyBroadcast(_, let options),
             .solanaSerializedBroadcast(_, let options):
            return SolanaClusterOptions(suggestedCluster: options.clusterHint)
        case .signature:
            return nil
        }
    }

    public init(subject: ApprovalSubject, walletId: String, account: WalletAccount, meta: String, payload: Payload, solanaEndpoints: [Solana.Cluster: SolanaRPCEndpoint] = [:]) {
        self.subject = subject
        self.walletId = walletId
        self.account = account
        self.meta = meta
        self.payload = payload
        self.solanaEndpoints = solanaEndpoints
    }
}


public struct SolanaClusterOptions {
    public let suggestedCluster: Solana.Cluster?
    public var clusters: [Solana.Cluster] { Solana.Cluster.allCases }


    public init(suggestedCluster: Solana.Cluster?) {
        self.suggestedCluster = suggestedCluster
    }
}


public struct SendTransactionAction: Sendable {
    public let transaction: Transaction
    public let resolvedNetwork: ResolvedEthereumNetwork
    public let walletId: String
    public let account: WalletAccount

    public var chain: EthereumNetwork {
        return resolvedNetwork.network
    }

    public var rpcSource: RPCSource {
        return resolvedNetwork.source
    }

    public init(transaction: Transaction, resolvedNetwork: ResolvedEthereumNetwork, walletId: String, account: WalletAccount) {
        self.transaction = transaction
        self.resolvedNetwork = resolvedNetwork
        self.walletId = walletId
        self.account = account
    }
}


public struct AddEthereumChainAction: Sendable {
    public let chainToAdd: EthereumNetworkFromDapp

    public init(chainToAdd: EthereumNetworkFromDapp) {
        self.chainToAdd = chainToAdd
    }
}

