// ∅ 2026 lil org

import Foundation

struct SolanaDappRequestProcessor {

    private static let solana = Solana.shared

    private enum ProviderError: Error {
        case internalError
        case malformedPayload
        case unauthorized(publicKey: String)
        case sendTransaction(Solana.SendTransactionError)

        var responseError: ProviderResponseError {
            switch self {
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
        catalog: WalletReviewCatalog
    ) -> DappRequestPreparation {
        switch body.method {
        case .connect:
            return prepareConnect(request: request, body: body, catalog: catalog)
        case .signAllTransactions, .signMessage, .signTransaction, .signAndSendTransaction:
            return prepareSigningOrSending(
                request: request,
                body: body,
                catalog: catalog
            )
        }
    }

    static func prepareWithoutWallets(
        request: SafariRequest,
        body: SafariRequest.Solana
    ) -> DappRequestPreparation? {
        switch body.method {
        case .connect:
            if let account = request.authorizedAccount, account.coin == .solana {
                return .immediate(.existingSolanaConnection)
            }
            if body.onlyIfTrusted {
                return .immediate(immediateFailure(to: request, error: .unauthorized(publicKey: body.publicKey)))
            }
            return nil
        case .signAllTransactions:
            guard body.messages != nil else {
                return .immediate(immediateFailure(to: request, error: .malformedPayload))
            }
            return nil
        case .signMessage, .signTransaction, .signAndSendTransaction:
            return nil
        }
    }

    static func signingReviewContent(for body: SafariRequest.Solana) -> SigningReviewContent? {
        try? preparedSigningReviewContent(body: body).get()
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
        request: SafariRequest,
        body: SafariRequest.Solana,
        catalog: WalletReviewCatalog
    ) -> DappRequestPreparation {
        if let response = prepareWithoutWallets(request: request, body: body) { return response }
        let action = SelectAccountAction(
            coinType: .solana,
            selectedAccounts: Set(catalog.suggestedAccounts(coin: .solana)),
            initiallyConnectedProviders: [],
            network: nil
        )
        return .approval(.selectAccount(action))
    }

    private static func prepareSigningOrSending(
        request: SafariRequest,
        body: SafariRequest.Solana,
        catalog: WalletReviewCatalog
    ) -> DappRequestPreparation {
        if body.method == .signAllTransactions, body.messages == nil {
            return .immediate(immediateFailure(to: request, error: .malformedPayload))
        }

        let walletID: String
        let account: WalletAccount
        switch walletAndAccount(
            authorizedAccount: request.authorizedAccount,
            publicKey: body.publicKey,
            catalog: catalog
        ) {
        case .success(let value):
            (walletID, account) = value
        case .failure(let error):
            return .immediate(immediateFailure(to: request, error: error))
        }

        switch preparedSigningReviewContent(body: body) {
        case .success(let content):
            return .approval(.approveMessage(SignMessageAction(
                subject: content.subject,
                walletId: walletID,
                account: account,
                meta: content.meta,
                payload: content.payload
            )))
        case .failure(let error):
            return .immediate(immediateFailure(to: request, error: error))
        }
    }

    private static func preparedSigningReviewContent(
        body: SafariRequest.Solana
    ) -> Result<SigningReviewContent, ProviderError> {
        switch body.method {
        case .signAllTransactions:
            return signAllTransactionsReviewContent(body: body)
        case .signAndSendTransaction:
            return signAndSendReviewContent(body: body)
        case .signMessage, .signTransaction:
            return messageReviewContent(body: body)
        case .connect:
            return .failure(.internalError)
        }
    }

    private static func signAllTransactionsReviewContent(
        body: SafariRequest.Solana
    ) -> Result<SigningReviewContent, ProviderError> {
        guard let messages = body.messages else {
            return .failure(.malformedPayload)
        }

        var preparedMessages = [SolanaPreparedTransactionMessage]()
        preparedMessages.reserveCapacity(messages.count)
        for message in messages {
            switch preparedTransactionMessage(message, publicKey: body.publicKey) {
            case .success(let preparedMessage):
                preparedMessages.append(preparedMessage)
            case .failure(let error):
                return .failure(error)
            }
        }

        return .success(SigningReviewContent(
            subject: .approveTransaction,
            meta: SolanaTransactionSummaryFormatter.approvalMessage(
                encodedMessages: messages,
                preparedMessages: preparedMessages
            ),
            payload: .solanaTransactions(preparedMessages)
        ))
    }

    private static func signAndSendReviewContent(
        body: SafariRequest.Solana
    ) -> Result<SigningReviewContent, ProviderError> {
        let sendOptions: Solana.PreparedSendOptions
        switch Solana.preparedSendOptions(from: body.sendOptions) {
        case .success(let value):
            sendOptions = value
        case .failure(let error):
            return .failure(.sendTransaction(error))
        }

        if let serializedTransaction = body.transaction {
            return solana.preparedSerializedTransactionForSignAndSend(
                serializedTransaction: serializedTransaction,
                publicKey: body.publicKey
            ).map { transaction in
                SigningReviewContent(
                    subject: .approveTransaction,
                    meta: transactionApprovalMessage(
                        message: transaction.approvalMessage,
                        preparedMessage: transaction.preparedMessage
                    ),
                    payload: .solanaSerializedBroadcast(transaction, sendOptions)
                )
            }.mapError(ProviderError.sendTransaction)
        }

        return preparedLegacySignAndSendTransaction(body: body).map { transaction in
            SigningReviewContent(
                subject: .approveTransaction,
                meta: transactionApprovalMessage(
                    message: transaction.approvalMessage,
                    preparedMessage: transaction.preparedMessage
                ),
                payload: .solanaLegacyBroadcast(transaction, sendOptions)
            )
        }
    }

    private static func messageReviewContent(
        body: SafariRequest.Solana
    ) -> Result<SigningReviewContent, ProviderError> {
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
            return .success(SigningReviewContent(
                subject: .signMessage,
                meta: approvalMessage(
                    for: body,
                    canonicalMessage: canonicalMessage,
                    decodedMessageData: messageData
                ),
                payload: .solanaMessage(messageData)
            ))
        case .signTransaction:
            return preparedTransactionMessage(
                canonicalMessage,
                publicKey: body.publicKey
            ).map { preparedMessage in
                SigningReviewContent(
                    subject: .approveTransaction,
                    meta: transactionApprovalMessage(
                        message: canonicalMessage,
                        preparedMessage: preparedMessage
                    ),
                    payload: .solanaTransaction(preparedMessage)
                )
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
        authorizedAccount: WalletAccountDescriptor?,
        publicKey: String,
        catalog: WalletReviewCatalog
    ) -> Result<(String, WalletAccount), ProviderError> {
        guard let authorizedAccount,
              authorizedAccount.coin == .solana,
              authorizedAccount.normalizedAddress == publicKey,
              let value = catalog.specificAccount(descriptor: authorizedAccount) else {
            return .failure(.unauthorized(publicKey: publicKey))
        }
        return .success((value.walletId, value.account))
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
                result: .string(expectedSignature)
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

    private static func immediateFailure(
        to request: SafariRequest,
        error: ProviderError
    ) -> ImmediateResolution {
        if case .unauthorized(let publicKey) = error {
            return .solanaAuthorizationDenied(publicKey: publicKey)
        }
        return .failure(error.responseError)
    }

    private static func response(
        to request: SafariRequest,
        sendResult: Result<String, Solana.SendTransactionError>
    ) -> ResponseToExtension {
        switch sendResult {
        case .success(let signature):
            return response(to: request, result: .string(signature))
        case .failure(let error):
            return response(to: request, error: .sendTransaction(error))
        }
    }

    private static func response(
        to request: SafariRequest,
        result: ResponseToExtension.Result
    ) -> ResponseToExtension {
        return ResponseToExtension(for: request, payload: .result(result))
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
