// ∅ 2026 lil org

import Foundation

enum DappRequestAction: Sendable {
    case switchAccount(SelectAccountAction)
    case selectAccount(SelectAccountAction)
    case approveMessage(SignMessageAction)
    case approveTransaction(SendTransactionAction)
    case addEthereumChain(AddEthereumChainAction)

    var signingAccount: WalletAccountDescriptor? {
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

enum DappRequestPreparation: Sendable {
    case needsCatalog
    case immediate(ImmediateResolution)
    case approval(BoundApprovalIntent)
    case unavailable
}

enum UnboundDappRequestPreparation: Sendable {
    case needsCatalog
    case immediate(ImmediateResolution)
    case approval(DappRequestAction)
    case unavailable
}

enum ImmediateResolution: Sendable {
    case failure(ProviderResponseError)
    case solanaAuthorizationDenied(publicKey: String)
    case existingEthereumAccounts
    case existingSolanaConnection
    case ethereumRecoveredAddress(String)
    case ethereumChain(String)

    func response(
        for request: SafariRequest,
        networkResolver: (Int) -> EthereumNetworkResolution = { Nodes.resolution(chainId: $0) },
        customDefinitionResult: (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult = {
            Networks.existingCustomDefinitionResult(networkFromDapp: $0)
        }
    ) -> ResponseToExtension? {
        switch self {
        case .failure(let error):
            return ResponseToExtension(for: request, payload: .error(error))
        case .solanaAuthorizationDenied(let publicKey):
            guard case .solana(let body) = request.body,
                  body.publicKey == publicKey else { return nil }
            return ResponseToExtension(
                for: request,
                payload: .error(.init(
                    message: Strings.providerNotReady, code: 4100,
                    context: .unauthorizedPublicKey(publicKey)
                )),
                mutation: .revokeSolana(publicKey)
            )
        case .existingEthereumAccounts:
            guard case .ethereum(let body) = request.body,
                  body.method == .requestAccounts,
                  let account = request.authorizedAccount,
                  account.coin == .ethereum else { return nil }
            return ResponseToExtension(
                for: request, payload: .result(.strings([account.normalizedAddress]))
            )
        case .existingSolanaConnection:
            guard case .solana(let body) = request.body,
                  body.method == .connect,
                  let account = request.authorizedAccount,
                  account.coin == .solana else { return nil }
            return ResponseToExtension(
                for: request, payload: .result(.solanaPublicKey(account.normalizedAddress))
            )
        case .ethereumRecoveredAddress(let address):
            guard case .ethereum(let body) = request.body,
                  body.method == .ecRecover else { return nil }
            return ResponseToExtension(for: request, payload: .result(.string(address)))
        case .ethereumChain(let chainID):
            guard case .ethereum(let body) = request.body,
                  let target = Int(hexString: chainID), target > 0,
                  String.hex(target, withPrefix: true) == chainID,
                  case .resolved(let network) = networkResolver(target) else { return nil }
            switch body.method {
            case .switchEthereumChain:
                guard body.switchToChainId == target else { return nil }
                if !body.address.isEmpty {
                    guard let account = request.authorizedAccount, account.coin == .ethereum,
                          account.normalizedAddress == WalletCoin.ethereum.normalizedAddress(body.address) else { return nil }
                }
            case .addEthereumChain:
                guard let definition = EthereumNetworkFromDapp.from(body.parameters),
                      Int(hexString: definition.chainId) == target,
                      EthereumDappRequestProcessor.existingChainAdditionMatches(
                        approvedNetwork: definition,
                        resolvedNetwork: network,
                        customDefinitionResult: customDefinitionResult
                      ) else { return nil }
            default:
                return nil
            }
            return ResponseToExtension(
                for: request, payload: .result(.null), mutation: .ethereumChain(chainID)
            )
        }
    }
}

enum ApprovedExecutionResult: Sendable {
    case completed(ApprovedCompletion)
    case broadcast(PreparedBroadcast)
    case rollback
}

@MainActor
protocol ApprovedBroadcastSending {
    func sendEthereum(
        signedTransaction: String,
        network: ResolvedEthereumNetwork
    ) async -> Result<String, EthereumSendFailure>

    func sendSolana(
        signedTransaction: String,
        cluster: Solana.Cluster,
        options: Solana.PreparedSendOptions
    ) async -> Result<String, Solana.SendTransactionError>
}

struct DappBroadcastSender: ApprovedBroadcastSending {
    private let ethereum: Ethereum?
    private let solana: Solana?

    nonisolated init(ethereum: Ethereum? = nil, solana: Solana? = nil) {
        self.ethereum = ethereum
        self.solana = solana
    }

    func sendEthereum(
        signedTransaction: String,
        network: ResolvedEthereumNetwork
    ) async -> Result<String, EthereumSendFailure> {
        do {
            return .success(try await (ethereum ?? .shared).sendSignedTransaction(
                signedTransaction, network: network.network
            ))
        } catch {
            return .failure(error as? EthereumSendFailure ?? .transport)
        }
    }

    func sendSolana(
        signedTransaction: String,
        cluster: Solana.Cluster,
        options: Solana.PreparedSendOptions
    ) async -> Result<String, Solana.SendTransactionError> {
        do {
            return .success(try await (solana ?? .shared).sendSignedTransaction(
                signedTransaction, cluster: cluster, sendOptions: options
            ))
        } catch {
            return .failure(error as? Solana.SendTransactionError ?? .unknown)
        }
    }
}

struct SelectAccountAction: Sendable {
    let coinType: WalletCoin?
    let selectedAccounts: Set<SpecificWalletAccount>
    let initiallyConnectedProviders: Set<InpageProvider>
    let network: EthereumNetwork?
}

struct SigningReviewContent: Sendable {
    let subject: ApprovalSubject
    let meta: String
    let payload: SignMessageAction.Payload
}

enum SignaturePayload: Sendable {
    case ethereumPersonalMessage(Data)
    case ethereumTypedData(String)
    case solanaMessage(Data)
    case solanaTransaction(SolanaPreparedTransactionMessage)
    case solanaTransactions([SolanaPreparedTransactionMessage])

    var coin: WalletCoin {
        switch self {
        case .ethereumPersonalMessage, .ethereumTypedData:
            return .ethereum
        case .solanaMessage, .solanaTransaction, .solanaTransactions:
            return .solana
        }
    }
}

struct SignMessageAction: Sendable {
    enum Payload: Sendable {
        case signature(SignaturePayload)
        case solanaLegacyBroadcast(
            Solana.PreparedLegacySignAndSendTransaction,
            Solana.PreparedSendOptions
        )
        case solanaSerializedBroadcast(
            Solana.PreparedSerializedTransaction,
            Solana.PreparedSendOptions
        )

        var coin: WalletCoin {
            switch self {
            case .signature(let payload):
                return payload.coin
            case .solanaLegacyBroadcast, .solanaSerializedBroadcast:
                return .solana
            }
        }
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
        case .signature:
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

struct SendTransactionAction: Sendable {
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

struct AddEthereumChainAction: Sendable {
    let chainToAdd: EthereumNetworkFromDapp
}
