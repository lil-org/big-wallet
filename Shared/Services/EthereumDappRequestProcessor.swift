// ∅ 2026 lil org

import Foundation

struct EthereumDappRequestProcessor {

    private static let ethereum = Ethereum.shared

    static func prepare(
        request: SafariRequest,
        body: SafariRequest.Ethereum,
        catalog: WalletReviewCatalog
    ) -> DappRequestPreparation {
        prepareAvailable(request: request, body: body, catalog: catalog)
            ?? .immediate(immediateFailure(to: request, error: .internalError))
    }

    static func prepareWithoutWallets(
        request: SafariRequest,
        body: SafariRequest.Ethereum
    ) -> DappRequestPreparation? {
        prepareAvailable(request: request, body: body, catalog: nil)
    }

    private static func prepareAvailable(
        request: SafariRequest,
        body: SafariRequest.Ethereum,
        catalog: WalletReviewCatalog?
    ) -> DappRequestPreparation? {
        lazy var walletAndAccount = request.authorizedAccount.flatMap { descriptor in
            guard descriptor.coin == .ethereum,
                  descriptor.normalizedAddress == WalletCoin.ethereum.normalizedAddress(body.address)
            else { return nil as SpecificWalletAccount? }
            return catalog?.specificAccount(descriptor: descriptor)
        }.map { ($0.walletId, $0.account) }

        switch body.method {
        case .addEthereumChain:
            return prepareAddChain(request: request, body: body)
        case .requestAccounts:
            if let account = request.authorizedAccount, account.coin == .ethereum {
                return .immediate(.existingEthereumAccounts)
            }
            guard let catalog else { return nil }
            let action = SelectAccountAction(
                coinType: .ethereum,
                selectedAccounts: Set(catalog.suggestedAccounts(coin: .ethereum)),
                initiallyConnectedProviders: [],
                network: nil
            )
            return .approval(.selectAccount(action))
        case .signTypedMessage:
            guard let raw = body.raw else {
                return .immediate(immediateGenericFailure(to: request))
            }
            guard catalog != nil else { return nil }
            guard let walletAndAccount else {
                return .immediate(immediateGenericFailure(to: request))
            }
            return prepareMessageSigning(
                walletId: walletAndAccount.0,
                account: walletAndAccount.1,
                subject: .signTypedData,
                meta: raw,
                payload: .ethereumTypedData(raw)
            )
        case .signMessage:
            guard let data = body.message else {
                return .immediate(immediateGenericFailure(to: request))
            }
            guard catalog != nil else { return nil }
            guard let walletAndAccount else {
                return .immediate(immediateGenericFailure(to: request))
            }
            return prepareMessageSigning(
                walletId: walletAndAccount.0,
                account: walletAndAccount.1,
                subject: .signMessage,
                meta: WalletCrypto.hexString(data: data),
                payload: .ethereumMessage(data)
            )
        case .signPersonalMessage:
            guard let data = body.message else {
                return .immediate(immediateGenericFailure(to: request))
            }
            guard catalog != nil else { return nil }
            guard let walletAndAccount else {
                return .immediate(immediateGenericFailure(to: request))
            }
            let text = String(data: data, encoding: .utf8) ?? WalletCrypto.hexString(data: data)
            return prepareMessageSigning(
                walletId: walletAndAccount.0,
                account: walletAndAccount.1,
                subject: .signPersonalMessage,
                meta: text,
                payload: .ethereumPersonalMessage(data)
            )
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
            guard let chainId = body.currentChainId,
                  case .resolved(let resolvedNetwork) = Nodes.resolution(chainId: chainId) else {
                return .immediate(immediateFailure(to: request, error: .internalError))
            }
            guard catalog != nil else { return nil }
            guard let walletAndAccount else {
                return .immediate(immediateFailure(
                    to: request,
                    error: .init(message: Strings.providerNotReady, code: 4100)
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
               let recovered = ethereum.recover(signature: signature, message: message) {
                return .immediate(.ethereumRecoveredAddress(recovered))
            }
            return .immediate(immediateFailure(
                to: request,
                error: .init(message: Strings.failedToVerify)
            ))
        case .switchEthereumChain:
            guard let chainId = body.switchToChainId,
                  Nodes.url(chainId: chainId) != nil else {
                return .immediate(immediateFailure(
                    to: request,
                    error: .init(message: Strings.unrecognizedChainId, code: 4902)
                ))
            }
            if !body.address.isEmpty {
                guard catalog != nil else { return nil }
                guard walletAndAccount != nil else {
                    return .immediate(immediateFailure(
                        to: request,
                        error: .init(message: Strings.providerNotReady, code: 4100)
                    ))
                }
            }
            return .immediate(.ethereumChain(String.hex(chainId, withPrefix: true)))
        }
    }

    static func execute(
        permit: ExtensionBridge.ApprovedExecutionPermit,
        signer: (any WalletSigning)?
    ) async -> ApprovedExecutionResult {
        guard permit.isExecuting else { return .rollback }
        switch permit.approval.kind {
        case .signing:
            guard let signer else { return .rollback }
            switch await signer.sign() {
            case .success(let output):
                if let completion = ApprovedCompletion.signed(output, permit: permit) {
                    return .completed(completion)
                }
                if let broadcast = PreparedBroadcast.signed(output, permit: permit) {
                    return .broadcast(broadcast)
                }
                return approvedFailure(.internalError, permit: permit)
            case .failure(.authorizationUnavailable):
                return .rollback
            case .failure(.failedToSign):
                return approvedFailure(.init(message: Strings.failedToSign, code: ProviderResponseError.internalErrorCode), permit: permit)
            case .failure(.invalidTransaction):
                return approvedFailure(.internalError, permit: permit)
            }
        case .addEthereumChain:
            guard completeApprovedChainAddition(permit: permit),
                  let completion = ApprovedCompletion.chainAdded(permit: permit) else {
                return approvedFailure(.init(message: Strings.somethingWentWrong), permit: permit)
            }
            return .completed(completion)
        default:
            return approvedFailure(.internalError, permit: permit)
        }
    }

    private static func approvedFailure(
        _ error: ProviderResponseError,
        permit: ExtensionBridge.ApprovedExecutionPermit
    ) -> ApprovedExecutionResult {
        ApprovedCompletion.failure(error, permit: permit).map(ApprovedExecutionResult.completed) ?? .rollback
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
            return .init(message: Strings.somethingWentWrong, code: -32_602)
        case .unsupportedTransactionType:
            return .init(message: Strings.somethingWentWrong, code: 4200)
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
                message: Strings.failedToSend,
                code: ProviderResponseError.internalErrorCode
            )
        case .rpc(.notSubmitted):
            return .init(
                message: Strings.failedToSend,
                code: ProviderResponseError.internalErrorCode
            )
        }
    }

    private static func prepareAddChain(
        request: SafariRequest,
        body: SafariRequest.Ethereum
    ) -> DappRequestPreparation {
        guard let chainToAdd = EthereumNetworkFromDapp.from(body.parameters),
              let chainId = Int(hexString: chainToAdd.chainId),
              chainId > 0 else {
            return .immediate(immediateGenericFailure(to: request))
        }

        switch Nodes.resolution(chainId: chainId) {
        case .resolved(let resolvedNetwork):
            guard existingChainAdditionMatches(
                approvedNetwork: chainToAdd,
                resolvedNetwork: resolvedNetwork,
                customDefinitionResult: { network in
                    Networks.existingCustomDefinitionResult(
                        networkFromDapp: network
                    )
                }
            ) else {
                return .immediate(immediateGenericFailure(to: request))
            }
            return .immediate(.ethereumChain(String.hex(chainId, withPrefix: true)))
        case .catalogOwnedButUnavailable:
            return .immediate(immediateGenericFailure(to: request))
        case .unknown:
            guard chainToAdd.defaultRpcURL != nil else {
                return .immediate(immediateGenericFailure(to: request))
            }
            let action = AddEthereumChainAction(chainToAdd: chainToAdd)
            return .approval(.addEthereumChain(action))
        }
    }

    private static func completeApprovedChainAddition(
        permit: ExtensionBridge.ApprovedExecutionPermit
    ) -> Bool {
        guard permit.isExecuting,
              case .addEthereumChain(let action) = permit.approval.kind,
              case .ethereum(let body) = permit.request.body,
              body.method == .addEthereumChain,
              let chainId = Int(hexString: action.chainToAdd.chainId), chainId > 0 else { return false }
        let network = action.chainToAdd
        switch Nodes.resolution(chainId: chainId) {
        case .resolved(let resolvedNetwork):
            return resolvedNetwork.source != .custom ||
                Networks.existingCustomDefinitionResult(
                    networkFromDapp: network
                ) == .matching
        case .catalogOwnedButUnavailable:
            return false
        case .unknown:
            guard Networks.add(networkFromDapp: network).succeeded,
                  case .resolved(let resolvedNetwork) = Nodes.resolution(chainId: chainId),
                  resolvedNetwork.source == .custom else {
                return false
            }
            return Networks.existingCustomDefinitionResult(
                networkFromDapp: network
            ) == .matching
        }
    }

    private static func prepareMessageSigning(
        walletId: String,
        account: WalletAccount,
        subject: ApprovalSubject,
        meta: String,
        payload: SignMessageAction.Payload
    ) -> DappRequestPreparation {
        .approval(.approveMessage(SignMessageAction(
            subject: subject,
            walletId: walletId,
            account: account,
            meta: meta,
            payload: payload
        )))
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
                message: Strings.transactionSubmissionStatusUnknown,
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
        .failure(.init(message: Strings.somethingWentWrong))
    }
}
