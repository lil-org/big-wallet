// ∅ 2026 lil org

import Foundation

struct SolanaDappRequestProcessor {

    private static let walletsManager = WalletsManager.shared
    private static let solana = Solana.shared

    private struct SigningPayload {
        let messageData: Data
        let approvalSubject: ApprovalSubject
        let approvalMessage: String
    }

    private enum ProviderError: Error {
        case canceled
        case failedToSign
        case internalError
        case malformedPayload
        case unauthorized(publicKey: String)
        case sendTransaction(Solana.SendTransactionError)

        var responseError: ProviderResponseError {
            switch self {
            case .canceled:
                return .userRejected
            case .failedToSign:
                return .init(
                    message: Strings.failedToSign,
                    code: ProviderResponseError.internalErrorCode
                )
            case .internalError:
                return .internalError
            case .malformedPayload:
                return .init(message: Strings.somethingWentWrong, code: 4200)
            case .unauthorized(let publicKey):
                return .init(
                    message: Strings.providerNotReady,
                    code: 4100,
                    context: .unauthorizedPublicKey(publicKey)
                )
            case .sendTransaction(let error):
                return sendTransactionResponseError(error)
            }
        }
    }

    static func prepare(
        request: SafariRequest,
        body: SafariRequest.Solana
    ) -> DappRequestPreparation {
        switch body.method {
        case .connect:
            return prepareConnect(request: request)
        case .signAllTransactions:
            return prepareSignAllTransactions(request: request, body: body)
        case .signMessage, .signTransaction, .signAndSendTransaction:
            return prepareSigningOrSending(request: request, body: body)
        }
    }

    static func prepareWithoutWallets(
        request: SafariRequest,
        body: SafariRequest.Solana
    ) -> DappRequestPreparation? {
        switch body.method {
        case .connect:
            return nil
        case .signAllTransactions:
            guard body.messages != nil else {
                return .response(response(to: request, error: .malformedPayload))
            }
            return nil
        case .signMessage, .signTransaction, .signAndSendTransaction:
            return nil
        }
    }

    static func decodedSignMessage(
        _ message: String,
        messageEncoding: SafariRequest.Solana.MessageEncoding
    ) -> Data? {
        switch messageEncoding {
        case .hex:
            return solana.decodeMessage(message, asHex: true)
        case .utf8:
            return message.data(using: .utf8)
        }
    }

    private static func prepareConnect(
        request: SafariRequest
    ) -> DappRequestPreparation {
        let action = SelectAccountAction(
            coinType: .solana,
            selectedAccounts: Set(walletsManager.suggestedAccounts(coin: .solana)),
            initiallyConnectedProviders: [],
            network: nil
        ) { _, selectedAccounts in
            guard let account = selectedAccounts?.first?.account,
                  account.coin == .solana else {
                return response(to: request, error: .canceled)
            }
            return response(
                to: request,
                body: .solana(.init(publicKey: account.address))
            )
        }
        return .approval(.selectAccount(action))
    }

    private static func prepareSignAllTransactions(
        request: SafariRequest,
        body: SafariRequest.Solana
    ) -> DappRequestPreparation {
        guard let messages = body.messages else {
            return .response(response(to: request, error: .malformedPayload))
        }

        let wallet: WalletContainer
        let account: WalletAccount
        switch walletAndAccount(publicKey: body.publicKey) {
        case .success(let value):
            (wallet, account) = value
        case .failure(let error):
            return .response(response(to: request, error: error))
        }

        var preparedMessages = [SolanaPreparedTransactionMessage]()
        preparedMessages.reserveCapacity(messages.count)
        for message in messages {
            switch preparedTransactionMessage(message, publicKey: body.publicKey) {
            case .success(let preparedMessage):
                preparedMessages.append(preparedMessage)
            case .failure(let error):
                return .response(response(to: request, error: error))
            }
        }

        let displayMessage = SolanaTransactionSummaryFormatter.approvalMessage(
            encodedMessages: messages,
            preparedMessages: preparedMessages
        )
        let messageDataList = preparedMessages.map(\.messageData)
        let action = approvalAction(
            request: request,
            wallet: wallet,
            account: account,
            subject: .approveTransaction,
            meta: displayMessage
        ) { privateKey in
            guard let results = await awaitBackgroundOptionalOperation({
                Solana.sign(
                    messageDataList: messageDataList,
                    privateKey: privateKey
                )
            }) else {
                return .response(response(to: request, error: .failedToSign))
            }
            return .response(response(
                to: request,
                solanaResponse: .init(results: results)
            ))
        }
        return .approval(action)
    }

    private static func prepareSigningOrSending(
        request: SafariRequest,
        body: SafariRequest.Solana
    ) -> DappRequestPreparation {
        let wallet: WalletContainer
        let account: WalletAccount
        switch walletAndAccount(publicKey: body.publicKey) {
        case .success(let value):
            (wallet, account) = value
        case .failure(let error):
            return .response(response(to: request, error: error))
        }

        switch body.method {
        case .signAndSendTransaction:
            return prepareSignAndSend(
                request: request,
                body: body,
                wallet: wallet,
                account: account
            )
        case .signMessage, .signTransaction:
            let payload: SigningPayload
            switch signingPayload(body: body) {
            case .success(let value):
                payload = value
            case .failure(let error):
                return .response(response(to: request, error: error))
            }
            let messageData = payload.messageData

            let action = approvalAction(
                request: request,
                wallet: wallet,
                account: account,
                subject: payload.approvalSubject,
                meta: payload.approvalMessage
            ) { privateKey in
                guard let signed = await awaitBackgroundOptionalOperation({
                    Solana.sign(
                        messageData: messageData,
                        privateKey: privateKey
                    )
                }) else {
                    return .response(response(to: request, error: .failedToSign))
                }
                return .response(response(
                    to: request,
                    solanaResponse: .init(result: signed)
                ))
            }
            return .approval(action)
        case .connect, .signAllTransactions:
            return .response(response(to: request, error: .internalError))
        }
    }

    private static func prepareSignAndSend(
        request: SafariRequest,
        body: SafariRequest.Solana,
        wallet: WalletContainer,
        account: WalletAccount
    ) -> DappRequestPreparation {
        let sendOptions: Solana.PreparedSendOptions
        switch Solana.preparedSendOptions(from: body.sendOptions) {
        case .success(let value):
            sendOptions = value
        case .failure(let error):
            return .response(response(to: request, error: .sendTransaction(error)))
        }

        let clusterSelection = SolanaClusterSelection(
            selectedCluster: sendOptions.clusterHint,
            suggestedCluster: sendOptions.clusterHint
        )
        if let serializedTransaction = body.transaction {
            return prepareSerializedSignAndSend(
                request: request,
                body: body,
                serializedTransaction: serializedTransaction,
                sendOptions: sendOptions,
                clusterSelection: clusterSelection,
                wallet: wallet,
                account: account
            )
        }

        let transaction: Solana.PreparedLegacySignAndSendTransaction
        switch preparedLegacySignAndSendTransaction(body: body) {
        case .success(let value):
            transaction = value
        case .failure(let error):
            return .response(response(to: request, error: error))
        }

        let action = approvalAction(
            request: request,
            wallet: wallet,
            account: account,
            subject: .approveTransaction,
            meta: transactionApprovalMessage(
                message: transaction.approvalMessage,
                preparedMessage: transaction.preparedMessage
            ),
            clusterSelection: clusterSelection
        ) { selectedCluster, privateKey in
            return await signAndSend(
                request: request,
                cluster: selectedCluster,
                sendOptions: sendOptions
            ) {
                Solana.signedTransactionForSignAndSend(
                    preparedLegacyTransaction: transaction,
                    privateKey: privateKey
                )
            }
        }
        return .approval(action)
    }

    private static func prepareSerializedSignAndSend(
        request: SafariRequest,
        body: SafariRequest.Solana,
        serializedTransaction: String,
        sendOptions: Solana.PreparedSendOptions,
        clusterSelection: SolanaClusterSelection,
        wallet: WalletContainer,
        account: WalletAccount
    ) -> DappRequestPreparation {
        switch solana.preparedSerializedTransactionForSignAndSend(
            serializedTransaction: serializedTransaction,
            publicKey: body.publicKey
        ) {
        case .failure(let error):
            return .response(response(to: request, error: .sendTransaction(error)))
        case .success(let transaction):
            let action = approvalAction(
                request: request,
                wallet: wallet,
                account: account,
                subject: .approveTransaction,
                meta: transactionApprovalMessage(
                    message: transaction.approvalMessage,
                    preparedMessage: transaction.preparedMessage
                ),
                clusterSelection: clusterSelection
            ) { selectedCluster, privateKey in
                return await signAndSend(
                    request: request,
                    cluster: selectedCluster,
                    sendOptions: sendOptions
                ) {
                    Solana.signedTransactionForSignAndSend(
                        preparedSerializedTransaction: transaction,
                        privateKey: privateKey
                    )
                }
            }
            return .approval(action)
        }
    }

    private static func signingPayload(
        body: SafariRequest.Solana
    ) -> Result<SigningPayload, ProviderError> {
        guard let canonicalMessage = body.message else {
            return .failure(.malformedPayload)
        }

        switch body.method {
        case .signMessage:
            guard let encoding = body.signMessageEncoding,
                  let messageData = decodedSignMessage(
                    canonicalMessage,
                    messageEncoding: encoding
                  ) else {
                return .failure(.malformedPayload)
            }
            return .success(SigningPayload(
                messageData: messageData,
                approvalSubject: .signMessage,
                approvalMessage: approvalMessage(
                    for: body,
                    canonicalMessage: canonicalMessage,
                    decodedMessageData: messageData
                )
            ))
        case .signTransaction:
            switch preparedTransactionMessage(canonicalMessage, publicKey: body.publicKey) {
            case .success(let preparedMessage):
                return .success(SigningPayload(
                    messageData: preparedMessage.messageData,
                    approvalSubject: .approveTransaction,
                    approvalMessage: transactionApprovalMessage(
                        message: canonicalMessage,
                        preparedMessage: preparedMessage
                    )
                ))
            case .failure(let error):
                return .failure(error)
            }
        case .connect, .signAllTransactions, .signAndSendTransaction:
            return .failure(.internalError)
        }
    }

    private static func preparedLegacySignAndSendTransaction(
        body: SafariRequest.Solana
    ) -> Result<Solana.PreparedLegacySignAndSendTransaction, ProviderError> {
        guard let message = body.message else {
            return .failure(.malformedPayload)
        }
        return solana.preparedLegacySignAndSendTransaction(
            message: message,
            publicKey: body.publicKey
        ).mapError(ProviderError.sendTransaction)
    }

    private static func preparedTransactionMessage(
        _ message: String,
        publicKey: String
    ) -> Result<SolanaPreparedTransactionMessage, ProviderError> {
        return solana.preparedTransactionMessageForSigning(
            message: message,
            publicKey: publicKey
        ).mapError(ProviderError.sendTransaction)
    }

    private static func approvalMessage(
        for body: SafariRequest.Solana,
        canonicalMessage: String,
        decodedMessageData: Data? = nil
    ) -> String {
        guard body.method == .signMessage, !body.displayHex else {
            return body.method == .signMessage
                ? canonicalMessage
                : SolanaTransactionSummaryFormatter.rawApprovalMessage(messages: [canonicalMessage])
        }
        guard let messageData = decodedMessageData ?? solana.decodeMessage(canonicalMessage, asHex: true),
              let messageText = String(data: messageData, encoding: .utf8),
              !messageText.isEmpty else {
            return canonicalMessage
        }
        return messageText
    }

    private static func transactionApprovalMessage(
        message: String,
        preparedMessage: SolanaPreparedTransactionMessage
    ) -> String {
        return SolanaTransactionSummaryFormatter.approvalMessage(
            encodedMessages: [message],
            preparedMessages: [preparedMessage]
        )
    }

    private static func walletAndAccount(
        publicKey: String
    ) -> Result<(WalletContainer, WalletAccount), ProviderError> {
        guard let value = walletsManager.getWalletAndAccount(
            coin: .solana,
            address: publicKey
        ) else {
            return .failure(.unauthorized(publicKey: publicKey))
        }
        return .success(value)
    }

    private static func approvalAction(
        request: SafariRequest,
        wallet: WalletContainer,
        account: WalletAccount,
        subject: ApprovalSubject,
        meta: String,
        clusterSelection: SolanaClusterSelection,
        onApprove: @escaping (
            Solana.Cluster,
            WalletPrivateKey
        ) async -> DappExecutionResult
    ) -> DappRequestAction {
        return approvalAction(
            request: request,
            wallet: wallet,
            account: account,
            subject: subject,
            meta: meta,
            solanaClusterSelection: clusterSelection
        ) { privateKey in
            guard let selectedCluster = clusterSelection.selectedCluster else {
                return .response(response(to: request, error: .internalError))
            }
            return await onApprove(selectedCluster, privateKey)
        }
    }

    private static func approvalAction(
        request: SafariRequest,
        wallet: WalletContainer,
        account: WalletAccount,
        subject: ApprovalSubject,
        meta: String,
        solanaClusterSelection: SolanaClusterSelection? = nil,
        onApprove: @escaping (WalletPrivateKey) async -> DappExecutionResult
    ) -> DappRequestAction {
        let action = SignMessageAction(
            subject: subject,
            walletId: wallet.id,
            account: account,
            meta: meta,
            solanaClusterSelection: solanaClusterSelection
        ) { approved in
            guard approved else {
                return .response(response(to: request, error: .canceled))
            }
            guard let privateKey = walletsManager.getPrivateKey(
                walletId: wallet.id,
                account: account
            ) else {
                return .response(response(to: request, error: .failedToSign))
            }
            return await onApprove(privateKey)
        }
        return .approveMessage(action)
    }

    private static func signAndSend(
        request: SafariRequest,
        cluster: Solana.Cluster,
        sendOptions: Solana.PreparedSendOptions,
        signing: @escaping @Sendable () -> Result<String, Solana.SendTransactionError>
    ) async -> DappExecutionResult {
        guard let signingResult = await awaitBackgroundOperation(signing) else {
            return .response(ResponseToExtension(
                for: request,
                payload: .error(.internalError)
            ))
        }
        switch signingResult {
        case .failure(let error):
            return .response(response(to: request, sendResult: .failure(error)))
        case .success(let signedTransaction):
            guard let expectedSignature = Solana.transactionSignature(
                signedTransaction: signedTransaction
            ) else {
                return .response(ResponseToExtension(
                    for: request,
                    payload: .error(.internalError)
                ))
            }
            let recoveryResponse = transactionSubmissionUnknownResponse(
                to: request,
                signature: expectedSignature
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
                        solana.sendSignedTransaction(
                            signedTransaction,
                            cluster: cluster,
                            sendOptions: sendOptions,
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
                        expectedSignature: expectedSignature,
                        recoveryResponse: recoveryResponse,
                        result: result
                    )
                }
            ))
        }
    }

    static func transactionBroadcastResponse(
        to request: SafariRequest,
        expectedSignature: String,
        recoveryResponse: ResponseToExtension,
        result: Result<String, Solana.SendTransactionError>
    ) -> ResponseToExtension {
        switch result {
        case .success(let signature):
            guard signature == expectedSignature else {
                return recoveryResponse
            }
            return response(
                to: request,
                solanaResponse: .init(result: expectedSignature)
            )
        case .failure(let error):
            switch error {
            case .confirmationFailed(let signature, _, _),
                 .confirmationTimedOut(let signature):
                guard signature == expectedSignature else {
                    return recoveryResponse
                }
            case .unknown:
                return recoveryResponse
            case .rpcError(let message, let code)
                where code == -32_002 &&
                    message.range(of: "already", options: .caseInsensitive) != nil &&
                    message.range(of: "processed", options: .caseInsensitive) != nil:
                return recoveryResponse
            case .invalidMessage, .invalidSendOptions,
                 .blockhashNotFound, .unsupportedMultiSignature,
                 .rpcError, .rpcUnavailable, .notSubmitted:
                break
            }
            return response(to: request, sendResult: .failure(error))
        }
    }

    static func transactionSubmissionUnknownResponse(
        to request: SafariRequest,
        signature: String
    ) -> ResponseToExtension {
        return ResponseToExtension(
            for: request,
            payload: .error(.init(
                message: Strings.transactionSubmissionStatusUnknown,
                code: ProviderResponseError.transactionSubmissionUnknownCode,
                context: .transactionSignature(signature)
            ))
        )
    }

    private static func response(
        to request: SafariRequest,
        sendResult: Result<String, Solana.SendTransactionError>
    ) -> ResponseToExtension {
        switch sendResult {
        case .success(let signature):
            return response(to: request, solanaResponse: .init(result: signature))
        case .failure(let error):
            return response(to: request, error: .sendTransaction(error))
        }
    }

    private static func response(
        to request: SafariRequest,
        solanaResponse: ResponseToExtension.Solana
    ) -> ResponseToExtension {
        return response(to: request, body: .solana(solanaResponse))
    }

    private static func response(
        to request: SafariRequest,
        body: ResponseToExtension.Body
    ) -> ResponseToExtension {
        return ResponseToExtension(for: request, payload: .body(body))
    }

    private static func response(
        to request: SafariRequest,
        error: ProviderError
    ) -> ResponseToExtension {
        return ResponseToExtension(for: request, payload: .error(error.responseError))
    }

    private static func sendTransactionResponseError(
        _ error: Solana.SendTransactionError
    ) -> ProviderResponseError {
        switch error {
        case .invalidMessage:
            return .init(message: Strings.somethingWentWrong, code: 4200)
        case .invalidSendOptions:
            return .init(message: Strings.unsupportedSolanaSendOptions, code: 4200)
        case .blockhashNotFound:
            return .init(message: Strings.solanaBlockhashNotFound, code: -32003)
        case .confirmationFailed(let signature, let message, let code):
            return .init(
                message: message,
                code: code ?? -32005,
                context: .transactionSignature(signature)
            )
        case .confirmationTimedOut(let signature):
            return .init(
                message: Strings.solanaConfirmationTimedOut,
                code: -32005,
                context: .transactionSignature(signature)
            )
        case .unsupportedMultiSignature:
            return .init(message: Strings.failedToSend, code: 4200)
        case .rpcError(let message, let code):
            return .init(message: message, code: code ?? -32003)
        case .rpcUnavailable:
            return .internalError
        case .notSubmitted:
            return .init(
                message: Strings.failedToSend,
                code: ProviderResponseError.internalErrorCode
            )
        case .unknown:
            return .init(message: Strings.failedToSend, code: -32003)
        }
    }
}
