// ∅ 2026 lil org

import Foundation

struct EthereumDappRequestProcessor {

    private static let ethereum = Ethereum.shared

    static func prepare(
        request: SafariRequest,
        body: SafariRequest.Ethereum,
        walletAccess: WalletAccess = SourceWalletAccess.shared
    ) -> DappRequestPreparation {
        lazy var walletAndAccount = walletAccess.specificAccount(
            coin: .ethereum,
            address: body.address
        ).map { ($0.walletId, $0.account) }

        switch body.method {
        case .addEthereumChain:
            return prepareAddChain(request: request, body: body)
        case .requestAccounts:
            let action = SelectAccountAction(
                coinType: .ethereum,
                selectedAccounts: Set(walletAccess.suggestedAccounts(coin: .ethereum)),
                initiallyConnectedProviders: [],
                network: nil
            ) { chain, selectedAccounts in
                guard let chain,
                      let account = selectedAccounts?.first?.account,
                      account.coin == .ethereum else {
                    return response(to: request, error: .userRejected)
                }
                let body = ResponseToExtension.Ethereum(
                    results: [account.address],
                    chainId: chain.chainIdHexString
                )
                return response(to: request, body: .ethereum(body))
            }
            return .approval(.selectAccount(action))
        case .signTypedMessage:
            guard let walletAndAccount, let raw = body.raw else {
                return .response(genericFailureResponse(to: request))
            }
            return prepareMessageSigning(
                request: request,
                walletId: walletAndAccount.0,
                account: walletAndAccount.1,
                subject: .signTypedData,
                meta: raw,
                walletAccess: walletAccess,
                signing: { signTypedData(privateKey: $0, raw: raw) }
            )
        case .signMessage:
            guard let data = body.message, let walletAndAccount else {
                return .response(genericFailureResponse(to: request))
            }
            return prepareMessageSigning(
                request: request,
                walletId: walletAndAccount.0,
                account: walletAndAccount.1,
                subject: .signMessage,
                meta: WalletCrypto.hexString(data: data),
                walletAccess: walletAccess,
                signing: { signMessage(privateKey: $0, data: data) }
            )
        case .signPersonalMessage:
            guard let data = body.message, let walletAndAccount else {
                return .response(genericFailureResponse(to: request))
            }
            let text = String(data: data, encoding: .utf8) ?? WalletCrypto.hexString(data: data)
            return prepareMessageSigning(
                request: request,
                walletId: walletAndAccount.0,
                account: walletAndAccount.1,
                subject: .signPersonalMessage,
                meta: text,
                walletAccess: walletAccess,
                signing: { signPersonalMessage(privateKey: $0, data: data) }
            )
        case .signTransaction:
            let transaction: Transaction
            switch body.transactionParsingResult {
            case .success(let value):
                transaction = value
            case .failure(let error):
                return .response(response(
                    to: request,
                    error: transactionProviderError(for: error)
                ))
            }
            guard let chainId = body.currentChainId,
                  case .resolved(let resolvedNetwork) = Nodes.resolution(chainId: chainId) else {
                return .response(response(to: request, error: .internalError))
            }
            guard let walletAndAccount else {
                return .response(response(
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
            ) { approvedTransaction in
                guard let approvedTransaction else {
                    return .response(response(to: request, error: .userRejected))
                }
                guard let privateKey = privateKey(
                    walletId: walletId,
                    account: account,
                    walletAccess: walletAccess
                ) else {
                    return .response(signingFailedResponse(to: request))
                }
                return await prepareTransactionBroadcast(
                    privateKey: privateKey,
                    transaction: approvedTransaction,
                    resolvedNetwork: resolvedNetwork,
                    request: request
                )
            }
            return .approval(.approveTransaction(action))
        case .ecRecover:
            if let (signature, message) = body.signatureAndMessage,
               let recovered = ethereum.recover(signature: signature, message: message) {
                return .response(response(
                    to: request,
                    body: .ethereum(.init(result: recovered))
                ))
            }
            return .response(response(
                to: request,
                error: .init(message: Strings.failedToVerify)
            ))
        case .switchEthereumChain:
            guard let chainId = body.switchToChainId,
                  Nodes.url(chainId: chainId) != nil else {
                return .response(response(
                    to: request,
                    error: .init(message: Strings.unrecognizedChainId, code: 4902)
                ))
            }
            let results: [String]
            if body.address.isEmpty {
                results = []
            } else if let account = walletAndAccount?.1 {
                results = [account.address]
            } else {
                return .response(response(
                    to: request,
                    error: .init(message: Strings.providerNotReady, code: 4100)
                ))
            }
            return .response(response(
                to: request,
                body: .ethereum(.init(
                    results: results,
                    chainId: String.hex(chainId, withPrefix: true)
                ))
            ))
        }
    }

    static func prepareWithoutWallets(
        request: SafariRequest,
        body: SafariRequest.Ethereum
    ) -> DappRequestPreparation? {
        switch body.method {
        case .addEthereumChain, .ecRecover:
            return prepare(request: request, body: body)
        case .switchEthereumChain:
            guard let chainId = body.switchToChainId,
                  Nodes.url(chainId: chainId) != nil else {
                return prepare(request: request, body: body)
            }
            return body.address.isEmpty ? prepare(request: request, body: body) : nil
        case .signTransaction:
            switch body.transactionParsingResult {
            case .failure(let error):
                return .response(response(
                    to: request,
                    error: transactionProviderError(for: error)
                ))
            case .success:
                guard let chainId = body.currentChainId,
                      case .resolved = Nodes.resolution(chainId: chainId) else {
                    return .response(response(to: request, error: .internalError))
                }
                return nil
            }
        case .signTypedMessage:
            return body.raw == nil
                ? .response(genericFailureResponse(to: request))
                : nil
        case .signMessage, .signPersonalMessage:
            return body.message == nil
                ? .response(genericFailureResponse(to: request))
                : nil
        case .requestAccounts:
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
        case .invalidTransaction:
            return .internalError
        case .failedToSign:
            return .init(
                message: Strings.failedToSign,
                code: ProviderResponseError.internalErrorCode
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
            return .response(genericFailureResponse(to: request))
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
                return .response(genericFailureResponse(to: request))
            }
            let responseBody = ResponseToExtension.Ethereum(
                results: [body.address],
                chainId: chainToAdd.chainId
            )
            return .response(response(to: request, body: .ethereum(responseBody)))
        case .catalogOwnedButUnavailable:
            return .response(genericFailureResponse(to: request))
        case .unknown:
            guard chainToAdd.defaultRpcURL != nil else {
                return .response(genericFailureResponse(to: request))
            }
            let action = AddEthereumChainAction(chainToAdd: chainToAdd) { approved in
                guard approved else {
                    return response(to: request, error: .userRejected)
                }
                guard completeApprovedChainAddition(
                    chainToAdd,
                    chainId: chainId
                ) else {
                    return genericFailureResponse(to: request)
                }
                let responseBody = ResponseToExtension.Ethereum(
                    results: [body.address],
                    chainId: chainToAdd.chainId
                )
                return response(to: request, body: .ethereum(responseBody))
            }
            return .approval(.addEthereumChain(action))
        }
    }

    private static func completeApprovedChainAddition(
        _ network: EthereumNetworkFromDapp,
        chainId: Int
    ) -> Bool {
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

    private static func privateKey(
        walletId: String,
        account: WalletAccount,
        walletAccess: WalletAccess
    ) -> WalletPrivateKey? {
        walletAccess.privateKey(walletID: walletId, account: account)
    }

    private enum SigningResult: Sendable {
        case success(String)
        case failure
    }

    private static func prepareMessageSigning(
        request: SafariRequest,
        walletId: String,
        account: WalletAccount,
        subject: ApprovalSubject,
        meta: String,
        walletAccess: WalletAccess,
        signing: @escaping @Sendable (WalletPrivateKey) -> SigningResult
    ) -> DappRequestPreparation {
        let action = SignMessageAction(
            subject: subject,
            walletId: walletId,
            account: account,
            meta: meta
        ) { approved in
            guard approved else {
                return response(to: request, error: .userRejected)
            }
            guard let privateKey = privateKey(
                walletId: walletId,
                account: account,
                walletAccess: walletAccess
            ) else {
                return signingFailedResponse(to: request)
            }
            guard let result = await awaitBackgroundOperation({ signing(privateKey) }) else {
                return genericFailureResponse(to: request)
            }
            return response(to: request, signingResult: result)
        }
        return .approval(.approveMessage(action))
    }

    private static func signTypedData(
        privateKey: WalletPrivateKey,
        raw: String
    ) -> SigningResult {
        guard let signed = try? Ethereum.sign(typedData: raw, privateKey: privateKey) else {
            return .failure
        }
        return .success(signed)
    }

    private static func signMessage(
        privateKey: WalletPrivateKey,
        data: Data
    ) -> SigningResult {
        guard let signed = try? Ethereum.sign(data: data, privateKey: privateKey) else {
            return .failure
        }
        return .success(signed)
    }

    private static func signPersonalMessage(
        privateKey: WalletPrivateKey,
        data: Data
    ) -> SigningResult {
        guard let signed = try? Ethereum.signPersonalMessage(data: data, privateKey: privateKey) else {
            return .failure
        }
        return .success(signed)
    }

    private static func prepareTransactionBroadcast(
        privateKey: WalletPrivateKey,
        transaction: Transaction,
        resolvedNetwork: ResolvedEthereumNetwork,
        request: SafariRequest
    ) async -> DappExecutionResult {
        guard let signingResult = await awaitBackgroundOperation({
            Ethereum.signedTransaction(
                transaction: transaction,
                privateKey: privateKey,
                network: resolvedNetwork.network
            )
        }) else {
            return .response(ResponseToExtension(
                for: request,
                payload: .error(.internalError)
            ))
        }
        switch signingResult {
        case .failure(let failure):
            return .response(response(
                to: request,
                error: providerError(for: failure)
            ))
        case .success(let signedTransaction):
            guard let expectedHash = Ethereum.transactionHash(
                signedTransaction: signedTransaction
            ) else {
                return .response(ResponseToExtension(
                    for: request,
                    payload: .error(.internalError)
                ))
            }
            let recoveryResponse = transactionSubmissionUnknownResponse(
                to: request,
                transactionHash: expectedHash
            )
            return .broadcast(PreparedBroadcast(
                recoveryResponse: recoveryResponse,
                send: {
                    guard !Task.isCancelled else {
                        return ResponseToExtension(
                            for: request,
                            payload: .error(.internalError)
                        )
                    }
                    guard let result = await awaitCancellableCallback({ completion in
                        ethereum.sendSignedTransaction(
                            signedTransaction,
                            network: resolvedNetwork.network,
                            completion: completion
                        )
                    }) else {
                        return ResponseToExtension(
                            for: request,
                            payload: .error(.internalError)
                        )
                    }
                    return transactionBroadcastResponse(
                        to: request,
                        expectedHash: expectedHash,
                        recoveryResponse: recoveryResponse,
                        result: result
                    )
                }
            ))
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
                body: .ethereum(.init(result: expectedHash))
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
            case .invalidTransaction, .failedToSign,
                 .rpc(.serverError), .rpc(.notSubmitted):
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
        body: ResponseToExtension.Body
    ) -> ResponseToExtension {
        return ResponseToExtension(for: request, payload: .body(body))
    }

    private static func response(
        to request: SafariRequest,
        signingResult: SigningResult
    ) -> ResponseToExtension {
        switch signingResult {
        case .success(let signature):
            return response(to: request, body: .ethereum(.init(result: signature)))
        case .failure:
            return signingFailedResponse(to: request)
        }
    }

    private static func response(
        to request: SafariRequest,
        error: ProviderResponseError
    ) -> ResponseToExtension {
        return ResponseToExtension(for: request, payload: .error(error))
    }

    private static func genericFailureResponse(
        to request: SafariRequest
    ) -> ResponseToExtension {
        return response(to: request, error: .init(message: Strings.somethingWentWrong))
    }

    private static func signingFailedResponse(
        to request: SafariRequest
    ) -> ResponseToExtension {
        return response(
            to: request,
            error: .init(
                message: Strings.failedToSign,
                code: ProviderResponseError.internalErrorCode
            )
        )
    }
}
