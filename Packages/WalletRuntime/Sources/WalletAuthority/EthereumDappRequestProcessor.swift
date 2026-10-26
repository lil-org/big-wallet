import WalletDomain
import WalletStorageSupport
// ∅ 2026 lil org

import Foundation

struct EthereumDappRequestProcessor {

    @MainActor
    static func prepare(
        request: SafariRequest,
        body: SafariRequest.Ethereum,
        catalog: WalletReviewCatalog?,
        networkResolver: @MainActor (Int) -> ApprovalNetworkResolution,
        customDefinitionResult: @MainActor (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult
    ) -> UnboundDappRequestPreparation {
        lazy var walletAndAccount = request.authorizedAccount.flatMap { descriptor in
            guard descriptor.coin == .ethereum,
                  descriptor.normalizedAddress == WalletCoin.ethereum.normalizedAddress(body.address)
            else { return nil as SpecificWalletAccount? }
            return catalog?.specificAccount(descriptor: descriptor)
        }.map { ($0.walletId, $0.account) }

        switch body.method {
        case .addEthereumChain:
            return prepareAddChain(request: request, body: body, networkResolver: networkResolver,
                customDefinitionResult: customDefinitionResult)
        case .requestAccounts:
            if let account = request.authorizedAccount, account.coin == .ethereum {
                return .immediate(.existingEthereumAccounts)
            }
            guard let catalog else { return .needsCatalog }
            let action = SelectAccountAction(
                coinType: .ethereum,
                selectedAccounts: Set(catalog.suggestedAccounts(coin: .ethereum)),
                initiallyConnectedProviders: [],
                network: nil
            )
            return .approval(.selectAccount(action))
        case .signTypedMessage, .signPersonalMessage:
            guard let content = signingReviewContent(for: body) else {
                return .immediate(immediateGenericFailure(to: request))
            }
            guard catalog != nil else { return .needsCatalog }
            guard let walletAndAccount else {
                return .immediate(immediateGenericFailure(to: request))
            }
            return .approval(.approveMessage(SignMessageAction(
                subject: content.subject,
                walletId: walletAndAccount.0,
                account: walletAndAccount.1,
                meta: content.meta,
                payload: content.payload
            )))
        case .signTransaction:
            let transaction: Transaction
            switch body.transactionParsingResult {
            case .success(let value):
                transaction = value
            case .failure(let error):
                return .immediate(immediateFailure(
                    to: request,
                    error: transactionProviderError(for: error)
                ))
            }
            guard let chainId = body.currentChainId else {
                return .immediate(immediateFailure(to: request, error: .internalError))
            }
            let resolvedNetwork: ResolvedEthereumNetwork
            switch networkResolver(chainId) {
            case .resolved(let network): resolvedNetwork = network
            case .missing: return .immediate(.failure(.internalError))
            case .unavailable: return .unavailable
            }
            guard resolvedNetwork.network.chainId == chainId else {
                return .immediate(.failure(.internalError))
            }
            guard catalog != nil else { return .needsCatalog }
            guard let walletAndAccount else {
                return .immediate(immediateFailure(
                    to: request,
                    error: .init(message: AuthorityStrings.providerNotReady, code: 4100)
                ))
            }

            let walletId = walletAndAccount.0
            let account = walletAndAccount.1
            let action = SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: resolvedNetwork,
                walletId: walletId,
                account: account
            )
            return .approval(.approveTransaction(action))
        case .ecRecover:
            if let (signature, message) = body.signatureAndMessage,
               let recovered = EthereumSigner.recover(signature: signature, message: message) {
                return .immediate(.ethereumRecoveredAddress(recovered))
            }
            return .immediate(immediateFailure(
                to: request,
                error: .init(message: AuthorityStrings.failedToVerify)
            ))
        case .switchEthereumChain:
            guard let chainId = body.switchToChainId else {
                return .immediate(immediateFailure(
                    to: request,
                    error: .init(message: AuthorityStrings.unrecognizedChainId, code: 4902)
                ))
            }
            switch networkResolver(chainId) {
            case .resolved: break
            case .missing:
                return .immediate(.failure(.init(message: AuthorityStrings.unrecognizedChainId, code: 4902)))
            case .unavailable: return .unavailable
            }
            if !body.address.isEmpty {
                guard catalog != nil else { return .needsCatalog }
                guard walletAndAccount != nil else {
                    return .immediate(immediateFailure(
                        to: request,
                        error: .init(message: AuthorityStrings.providerNotReady, code: 4100)
                    ))
                }
            }
            return .immediate(.ethereumChain(String.hex(chainId, withPrefix: true)))
        }
    }

    static func signingReviewContent(for body: SafariRequest.Ethereum) -> SigningReviewContent? {
        switch body.method {
        case .signTypedMessage:
            guard let raw = body.raw else { return nil }
            return SigningReviewContent(
                subject: .signTypedData,
                meta: raw,
                payload: .signature(.ethereumTypedData(raw))
            )
        case .signPersonalMessage:
            guard let data = body.message else { return nil }
            return SigningReviewContent(
                subject: .signPersonalMessage,
                meta: String(data: data, encoding: .utf8) ?? WalletCrypto.hexString(data: data),
                payload: .signature(.ethereumPersonalMessage(data))
            )
        case .addEthereumChain, .requestAccounts, .signTransaction, .ecRecover, .switchEthereumChain:
            return nil
        }
    }

    static func existingChainAdditionMatches(
        approvedNetwork: EthereumNetworkFromDapp,
        resolvedNetwork: ResolvedEthereumNetwork,
        customDefinitionResult: (
            EthereumNetworkFromDapp
        ) -> CustomNetworkInsertionResult
    ) -> Bool {
        guard resolvedNetwork.source == .custom else { return true }
        return customDefinitionResult(approvedNetwork) == .matching
    }

    static func transactionProviderError(
        for error: TransactionParsingError
    ) -> ProviderResponseError {
        switch error {
        case .invalidParameters:
            return .init(message: AuthorityStrings.somethingWentWrong, code: -32_602)
        case .unsupportedTransactionType:
            return .init(message: AuthorityStrings.somethingWentWrong, code: 4200)
        }
    }

    static func providerError(for failure: EthereumSendFailure) -> ProviderResponseError {
        switch failure {
        case .rpc(.serverError(let code, let message, let dataJSON)):
            return .init(
                message: message,
                code: code,
                context: dataJSON.map(ProviderResponseError.Context.dataJSON)
            )
        case .rpc(.unknown), .transport:
            return .init(
                message: AuthorityStrings.failedToSend,
                code: ProviderResponseError.internalErrorCode
            )
        case .rpc(.notSubmitted):
            return .init(
                message: AuthorityStrings.failedToSend,
                code: ProviderResponseError.internalErrorCode
            )
        }
    }

    @MainActor
    private static func prepareAddChain(
        request: SafariRequest,
        body: SafariRequest.Ethereum,
        networkResolver: @MainActor (Int) -> ApprovalNetworkResolution,
        customDefinitionResult: @MainActor (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult
    ) -> UnboundDappRequestPreparation {
        guard let chainToAdd = EthereumNetworkFromDapp.from(body.parameters),
              let chainId = Int(hexString: chainToAdd.chainId),
              chainId > 0 else {
            return .immediate(immediateGenericFailure(to: request))
        }

        let network: EthereumNetworkResolution
        switch networkResolver(chainId) {
        case .resolved(let resolved): network = .resolved(resolved)
        case .missing: network = .unknown
        case .unavailable: return .unavailable
        }
        if let immediate = chainAdditionResolution(chainToAdd, networkResolver: { _ in network },
            customDefinitionResult: customDefinitionResult) {
            return .immediate(immediate)
        }
        return .approval(.addEthereumChain(AddEthereumChainAction(chainToAdd: chainToAdd)))
    }

    @MainActor
    static func chainAdditionResolution(
        _ chainToAdd: EthereumNetworkFromDapp,
        networkResolver: @MainActor (Int) -> EthereumNetworkResolution,
        customDefinitionResult: @MainActor (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult
    ) -> ImmediateResolution? {
        guard let chainId = Int(hexString: chainToAdd.chainId), chainId > 0 else {
            return .failure(.init(message: AuthorityStrings.somethingWentWrong))
        }
        switch networkResolver(chainId) {
        case .resolved(let resolvedNetwork):
            guard existingChainAdditionMatches(
                approvedNetwork: chainToAdd,
                resolvedNetwork: resolvedNetwork,
                customDefinitionResult: customDefinitionResult
            ) else {
                return .failure(.init(message: AuthorityStrings.somethingWentWrong))
            }
            return .ethereumChain(String.hex(chainId, withPrefix: true))
        case .catalogOwnedButUnavailable:
            return .failure(.init(message: AuthorityStrings.somethingWentWrong))
        case .unknown:
            guard chainToAdd.defaultRpcURL != nil else {
                return .failure(.init(message: AuthorityStrings.somethingWentWrong))
            }
            return nil
        }
    }

    static func completeApprovedChainAddition(
        permit: ExtensionBridge.ApprovedExecutionPermit,
        networkResolver: (Int) -> EthereumNetworkResolution,
        customDefinitionResult: (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult,
        insertNetwork: (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult
    ) -> Bool {
        guard permit.isExecuting,
              case .addEthereumChain(let action) = permit.approval.kind,
              case .ethereum(let body) = permit.request.body,
              body.method == .addEthereumChain,
              let chainId = Int(hexString: action.chainToAdd.chainId), chainId > 0 else { return false }
        let network = action.chainToAdd
        switch networkResolver(chainId) {
        case .resolved(let resolvedNetwork):
            return resolvedNetwork.source != .custom ||
                customDefinitionResult(network) == .matching
        case .catalogOwnedButUnavailable:
            return false
        case .unknown:
            guard insertNetwork(network).succeeded,
                  case .resolved(let resolvedNetwork) = networkResolver(chainId),
                  resolvedNetwork.source == .custom else {
                return false
            }
            return customDefinitionResult(network) == .matching
        }
    }

    static func transactionBroadcastResponse(
        to request: SafariRequest,
        expectedHash: String,
        recoveryResponse: ResponseToExtension,
        result: Result<String, EthereumSendFailure>
    ) -> ResponseToExtension {
        switch result {
        case .success(let hash):
            guard hash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
                return recoveryResponse
            }
            return response(
                to: request,
                result: .string(expectedHash)
            )
        case .failure(let failure):
            switch failure {
            case .rpc(.unknown), .transport:
                return recoveryResponse
            case .rpc(.serverError(let code, let message, _))
                where code == -32_000 &&
                    message.range(
                        of: "already known",
                        options: .caseInsensitive
                    ) != nil:
                return recoveryResponse
            case .rpc(.serverError), .rpc(.notSubmitted):
                return response(
                    to: request,
                    error: providerError(for: failure)
                )
            }
        }
    }

    static func transactionSubmissionUnknownResponse(
        to request: SafariRequest,
        transactionHash: String
    ) -> ResponseToExtension {
        return response(
            to: request,
            error: .init(
                message: AuthorityStrings.transactionSubmissionStatusUnknown,
                code: ProviderResponseError.transactionSubmissionUnknownCode,
                context: .transactionHash(transactionHash)
            )
        )
    }

    private static func response(
        to request: SafariRequest,
        result: ResponseToExtension.Result,
        mutation: ResponseToExtension.ConfigurationMutation? = nil
    ) -> ResponseToExtension {
        return ResponseToExtension(for: request, payload: .result(result), mutation: mutation)
    }

    private static func response(
        to request: SafariRequest,
        error: ProviderResponseError
    ) -> ResponseToExtension {
        return ResponseToExtension(for: request, payload: .error(error))
    }

    private static func immediateFailure(
        to request: SafariRequest,
        error: ProviderResponseError
    ) -> ImmediateResolution {
        .failure(error)
    }

    private static func immediateGenericFailure(to request: SafariRequest) -> ImmediateResolution {
        .failure(.init(message: AuthorityStrings.somethingWentWrong))
    }
}

