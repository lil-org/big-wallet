import Foundation
import WalletDomain

enum DappRequestPreparation: Sendable {
    case needsCatalog(@MainActor @Sendable (WalletReviewCatalog) -> DappRequestPreparation)
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
        networkResolver: (Int) -> EthereumNetworkResolution = { _ in .unknown },
        customDefinitionResult: (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult = { _ in .unavailable }
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
                    message: AuthorityStrings.providerNotReady, code: 4100,
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
