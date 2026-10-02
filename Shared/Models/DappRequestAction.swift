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
    case immediate(ImmediateResolution)
    case approval(BoundApprovalIntent)
}

enum UnboundDappRequestPreparation: Sendable {
    case immediate(ImmediateResolution)
    case approval(DappRequestAction)
}

enum ImmediateResolution: Sendable {
    case failure(ProviderResponseError)
    case solanaAuthorizationDenied(publicKey: String)
    case existingEthereumAccounts
    case existingSolanaConnection
    case ethereumRecoveredAddress(String)
    case ethereumChain(String)

    func response(for request: SafariRequest) -> ResponseToExtension? {
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
                  case .resolved(let network) = Nodes.resolution(chainId: target) else { return nil }
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
                        customDefinitionResult: Networks.existingCustomDefinitionResult
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

struct ApprovedCompletion: Sendable {
    let executionID: UUID
    private let value: ResponseToExtension

    private init(permit: ExtensionBridge.ApprovedExecutionPermit, response: ResponseToExtension) {
        executionID = permit.executionID
        value = response.markingApprovalCommitted()
    }

    func response(for permit: ExtensionBridge.ApprovedExecutionPermit) -> ResponseToExtension? {
        executionID == permit.executionID ? value : nil
    }

    static func failure(
        _ error: ProviderResponseError,
        permit: ExtensionBridge.ApprovedExecutionPermit
    ) -> ApprovedCompletion? {
        guard permit.isExecuting else { return nil }
        return ApprovedCompletion(
            permit: permit, response: ResponseToExtension(for: permit.request, payload: .error(error))
        )
    }

    static func accountSelection(
        permit: ExtensionBridge.ApprovedExecutionPermit
    ) -> ApprovedCompletion? {
        guard permit.isExecuting,
              case .accountSelection(let action, let selection) = permit.approval.kind else { return nil }
        return ApprovedCompletion(
            permit: permit,
            response: DappRequestProcessor.accountSelectionResponse(
                request: permit.request, action: action, selection: selection
            )
        )
    }

    static func signed(
        _ output: WalletSigningOutput,
        permit: ExtensionBridge.ApprovedExecutionPermit
    ) -> ApprovedCompletion? {
        guard permit.isExecuting,
              case .signing(_, let payload) = permit.approval.kind else { return nil }
        let result: ResponseToExtension.Result
        switch (payload, output) {
        case (.ethereumMessage, .ethereumSignature(let signature)),
             (.ethereumPersonalMessage, .ethereumSignature(let signature)),
             (.ethereumTypedData, .ethereumSignature(let signature)):
            result = .string(signature)
        case (.solanaMessage, .solanaSignature(let signature)),
             (.solanaTransaction, .solanaSignature(let signature)):
            result = .string(signature)
        case (.solanaTransactions(let transactions), .solanaSignatures(let signatures)):
            guard transactions.count == signatures.count else { return nil }
            result = .strings(signatures)
        default:
            return nil
        }
        return ApprovedCompletion(
            permit: permit, response: ResponseToExtension(for: permit.request, payload: .result(result))
        )
    }

    static func chainAdded(
        permit: ExtensionBridge.ApprovedExecutionPermit
    ) -> ApprovedCompletion? {
        guard permit.isExecuting,
              case .addEthereumChain(let action) = permit.approval.kind,
              case .ethereum(let body) = permit.request.body,
              body.method == .addEthereumChain,
              let chainID = Int(hexString: action.chainToAdd.chainId), chainID > 0 else { return nil }
        return ApprovedCompletion(
            permit: permit,
            response: ResponseToExtension(
                for: permit.request, payload: .result(.null),
                mutation: .ethereumChain(String.hex(chainID, withPrefix: true))
            )
        )
    }

    fileprivate static func broadcastResponse(
        _ response: ResponseToExtension,
        permit: ExtensionBridge.ApprovedExecutionPermit
    ) -> ApprovedCompletion {
        ApprovedCompletion(permit: permit, response: response)
    }
}

struct PreparedBroadcast: Sendable {
    private enum Transaction: Sendable {
        case ethereum(String, String, ResolvedEthereumNetwork)
        case solana(String, String, Solana.Cluster, Solana.PreparedSendOptions)
    }

    let executionID: UUID
    private let identity = UUID()
    private let transaction: Transaction

    private init(permit: ExtensionBridge.ApprovedExecutionPermit, transaction: Transaction) {
        executionID = permit.executionID
        self.transaction = transaction
    }

    func hasSameIdentity(as other: Self) -> Bool {
        executionID == other.executionID && identity == other.identity
    }

    static func signed(
        _ output: WalletSigningOutput,
        permit: ExtensionBridge.ApprovedExecutionPermit
    ) -> PreparedBroadcast? {
        guard permit.isExecuting,
              case .signing(_, let payload) = permit.approval.kind else { return nil }
        let transaction: Transaction
        switch (payload, output) {
        case (.ethereumTransaction(_, let network),
              .ethereumTransaction(let signed, let hash)):
            guard Ethereum.transactionHash(signedTransaction: signed)?.caseInsensitiveCompare(hash) == .orderedSame
            else { return nil }
            transaction = .ethereum(signed, hash, network)
        case (.solanaLegacyBroadcast(_, let options, let cluster),
              .solanaTransaction(let signed, let signature)),
             (.solanaSerializedBroadcast(_, let options, let cluster),
              .solanaTransaction(let signed, let signature)):
            guard Solana.transactionSignature(signedTransaction: signed) == signature else { return nil }
            transaction = .solana(signed, signature, cluster, options)
        default:
            return nil
        }
        return PreparedBroadcast(permit: permit, transaction: transaction)
    }

    func recoveryCompletion(
        for permit: ExtensionBridge.ApprovedExecutionPermit
    ) -> ApprovedCompletion? {
        guard executionID == permit.executionID else { return nil }
        let response: ResponseToExtension
        switch transaction {
        case .ethereum(_, let hash, _):
            response = EthereumDappRequestProcessor.transactionSubmissionUnknownResponse(
                to: permit.request, transactionHash: hash
            )
        case .solana(_, let signature, _, _):
            response = SolanaDappRequestProcessor.transactionSubmissionUnknownResponse(
                to: permit.request, signature: signature
            )
        }
        return .broadcastResponse(response, permit: permit)
    }

    @MainActor
    func dispatch(
        using dispatch: ExtensionBridge.BroadcastDispatchPermit,
        sender: any ApprovedBroadcastSending = DappBroadcastSender()
    ) async -> ApprovedCompletion? {
        let permit = dispatch.approvedPermit
        guard executionID == permit.executionID,
              executionID == dispatch.broadcast.executionID,
              identity == dispatch.broadcast.identity,
              dispatch.consume(), let recovery = recoveryCompletion(for: permit),
              let recoveryResponse = recovery.response(for: permit) else { return nil }
        let response: ResponseToExtension
        switch transaction {
        case .ethereum(let signed, let expectedHash, let network):
            guard !Task.isCancelled else { return recovery }
            let result = await sender.sendEthereum(signedTransaction: signed, network: network)
            response = EthereumDappRequestProcessor.transactionBroadcastResponse(
                to: permit.request, expectedHash: expectedHash,
                recoveryResponse: recoveryResponse, result: result
            )
        case .solana(let signed, let expectedSignature, let cluster, let options):
            guard !Task.isCancelled else { return recovery }
            let result = await sender.sendSolana(signedTransaction: signed, cluster: cluster, options: options)
            response = SolanaDappRequestProcessor.transactionBroadcastResponse(
                to: permit.request, expectedSignature: expectedSignature,
                recoveryResponse: recoveryResponse, result: result
            )
        }
        return .broadcastResponse(response, permit: permit)
    }
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
    nonisolated init() {}

    func sendEthereum(
        signedTransaction: String,
        network: ResolvedEthereumNetwork
    ) async -> Result<String, EthereumSendFailure> {
        await awaitCancellableCallback { completion in
            Ethereum.shared.sendSignedTransaction(
                signedTransaction, network: network.network, completion: completion
            )
        } ?? .failure(.transport)
    }

    func sendSolana(
        signedTransaction: String,
        cluster: Solana.Cluster,
        options: Solana.PreparedSendOptions
    ) async -> Result<String, Solana.SendTransactionError> {
        await awaitCancellableCallback { completion in
            Solana.shared.sendSignedTransaction(
                signedTransaction, cluster: cluster, sendOptions: options, completion: completion
            )
        } ?? .failure(.unknown)
    }
}

struct SelectAccountAction: Sendable {
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
}

struct SigningReviewContent: Sendable {
    let subject: ApprovalSubject
    let meta: String
    let payload: SignMessageAction.Payload
}

struct SignMessageAction: Sendable {
    enum Payload: Sendable {
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

        var coin: WalletCoin {
            switch self {
            case .ethereumMessage, .ethereumPersonalMessage, .ethereumTypedData:
                return .ethereum
            case .solanaMessage, .solanaTransaction, .solanaTransactions,
                 .solanaLegacyBroadcast, .solanaSerializedBroadcast:
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
