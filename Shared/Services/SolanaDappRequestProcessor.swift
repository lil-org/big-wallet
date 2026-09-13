// ∅ 2026 lil org

import Foundation

struct SolanaDappRequestProcessor {

    private static let solana = Solana.shared

    private struct SigningPayload {
        let payload: SignMessageAction.Payload
        let approvalSubject: ApprovalSubject
        let approvalMessage: String
    }

    private enum ProviderError: Error {
        case failedToSign
        case internalError
        case malformedPayload
        case unauthorized(publicKey: String)
        case sendTransaction(Solana.SendTransactionError)

        var responseError: ProviderResponseError {
            switch self {
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
        body: SafariRequest.Solana,
        walletAccess: WalletAccess = SourceWalletAccess.shared
    ) -> DappRequestPreparation {
        switch body.method {
        case .connect:
            return prepareConnect(walletAccess: walletAccess)
        case .signAllTransactions:
            return prepareSignAllTransactions(
                request: request,
                body: body,
                walletAccess: walletAccess
            )
        case .signMessage, .signTransaction, .signAndSendTransaction:
            return prepareSigningOrSending(
                request: request,
                body: body,
                walletAccess: walletAccess
            )
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

    static func execute(
        request: SafariRequest,
        action: DappRequestAction,
        decision: DappApprovalDecision,
        walletAccess: WalletAccess?
    ) async -> DappExecutionResult {
        guard case .approveMessage(let action) = action,
              case .message(let approval) = decision,
              (action.solanaClusterOptions != nil) == (approval.solanaCluster != nil)
        else { return .response(response(to: request, error: .internalError)) }
        guard let privateKey = walletAccess?.privateKey(
            walletID: action.walletId,
            account: action.account
        ) else { return .response(response(to: request, error: .failedToSign)) }

        switch action.payload {
        case .solanaMessage(let data):
            return await signMessage(data, privateKey: privateKey, request: request)
        case .solanaTransaction(let prepared):
            return await signMessage(
                prepared.messageData,
                privateKey: privateKey,
                request: request
            )
        case .solanaTransactions(let prepared):
            let messages = prepared.map(\.messageData)
            guard let results = await awaitBackgroundOptionalOperation({
                Solana.sign(messageDataList: messages, privateKey: privateKey)
            }) else { return .response(response(to: request, error: .failedToSign)) }
            return .response(response(to: request, solanaResponse: .init(results: results)))
        case .solanaLegacyBroadcast(let transaction, let options):
            guard let cluster = approval.solanaCluster else {
                return .response(response(to: request, error: .internalError))
            }
            return await signAndSend(request: request, cluster: cluster, sendOptions: options) {
                Solana.signedTransactionForSignAndSend(
                    preparedLegacyTransaction: transaction,
                    privateKey: privateKey
                )
            }
        case .solanaSerializedBroadcast(let transaction, let options):
            guard let cluster = approval.solanaCluster else {
                return .response(response(to: request, error: .internalError))
            }
            return await signAndSend(request: request, cluster: cluster, sendOptions: options) {
                Solana.signedTransactionForSignAndSend(
                    preparedSerializedTransaction: transaction,
                    privateKey: privateKey
                )
            }
        case .ethereumMessage, .ethereumPersonalMessage, .ethereumTypedData:
            return .response(response(to: request, error: .internalError))
        }
    }

    private static func signMessage(
        _ data: Data,
        privateKey: WalletPrivateKey,
        request: SafariRequest
    ) async -> DappExecutionResult {
        guard let signed = await awaitBackgroundOptionalOperation({
            Solana.sign(messageData: data, privateKey: privateKey)
        }) else { return .response(response(to: request, error: .failedToSign)) }
        return .response(response(to: request, solanaResponse: .init(result: signed)))
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
        walletAccess: WalletAccess
    ) -> DappRequestPreparation {
        let action = SelectAccountAction(
            coinType: .solana,
            selectedAccounts: Set(walletAccess.suggestedAccounts(coin: .solana)),
            initiallyConnectedProviders: [],
            network: nil
        )
        return .approval(.selectAccount(action))
    }

    private static func prepareSignAllTransactions(
        request: SafariRequest,
        body: SafariRequest.Solana,
        walletAccess: WalletAccess
    ) -> DappRequestPreparation {
        guard let messages = body.messages else {
            return .response(response(to: request, error: .malformedPayload))
        }

        let walletID: String
        let account: WalletAccount
        switch walletAndAccount(
            publicKey: body.publicKey,
            walletAccess: walletAccess
        ) {
        case .success(let value):
            (walletID, account) = value
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
        let action = approvalAction(
            walletID: walletID,
            account: account,
            subject: .approveTransaction,
            meta: displayMessage,
            payload: .solanaTransactions(preparedMessages)
        )
        return .approval(action)
    }

    private static func prepareSigningOrSending(
        request: SafariRequest,
        body: SafariRequest.Solana,
        walletAccess: WalletAccess
    ) -> DappRequestPreparation {
        let walletID: String
        let account: WalletAccount
        switch walletAndAccount(
            publicKey: body.publicKey,
            walletAccess: walletAccess
        ) {
        case .success(let value):
            (walletID, account) = value
        case .failure(let error):
            return .response(response(to: request, error: error))
        }

        switch body.method {
        case .signAndSendTransaction:
            return prepareSignAndSend(
                request: request,
                body: body,
                walletID: walletID,
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
            let action = approvalAction(
                walletID: walletID,
                account: account,
                subject: payload.approvalSubject,
                meta: payload.approvalMessage,
                payload: payload.payload
            )
            return .approval(action)
        case .connect, .signAllTransactions:
            return .response(response(to: request, error: .internalError))
        }
    }

    private static func prepareSignAndSend(
        request: SafariRequest,
        body: SafariRequest.Solana,
        walletID: String,
        account: WalletAccount
    ) -> DappRequestPreparation {
        let sendOptions: Solana.PreparedSendOptions
        switch Solana.preparedSendOptions(from: body.sendOptions) {
        case .success(let value):
            sendOptions = value
        case .failure(let error):
            return .response(response(to: request, error: .sendTransaction(error)))
        }

        if let serializedTransaction = body.transaction {
            return prepareSerializedSignAndSend(
                request: request,
                body: body,
                serializedTransaction: serializedTransaction,
                sendOptions: sendOptions,
                walletID: walletID,
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
            walletID: walletID,
            account: account,
            subject: .approveTransaction,
            meta: transactionApprovalMessage(
                message: transaction.approvalMessage,
                preparedMessage: transaction.preparedMessage
            ),
            payload: .solanaLegacyBroadcast(transaction, sendOptions)
        )
        return .approval(action)
    }

    private static func prepareSerializedSignAndSend(
        request: SafariRequest,
        body: SafariRequest.Solana,
        serializedTransaction: String,
        sendOptions: Solana.PreparedSendOptions,
        walletID: String,
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
                walletID: walletID,
                account: account,
                subject: .approveTransaction,
                meta: transactionApprovalMessage(
                    message: transaction.approvalMessage,
                    preparedMessage: transaction.preparedMessage
                ),
                payload: .solanaSerializedBroadcast(transaction, sendOptions)
            )
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
                payload: .solanaMessage(messageData),
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
                    payload: .solanaTransaction(preparedMessage),
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
        publicKey: String,
        walletAccess: WalletAccess
    ) -> Result<(String, WalletAccount), ProviderError> {
        guard let value = walletAccess.specificAccount(
            coin: .solana,
            address: publicKey
        ) else {
            return .failure(.unauthorized(publicKey: publicKey))
        }
        return .success((value.walletId, value.account))
    }

    private static func approvalAction(
        walletID: String,
        account: WalletAccount,
        subject: ApprovalSubject,
        meta: String,
        payload: SignMessageAction.Payload
    ) -> DappRequestAction {
        .approveMessage(SignMessageAction(
            subject: subject,
            walletId: walletID,
            account: account,
            meta: meta,
            payload: payload
        ))
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
