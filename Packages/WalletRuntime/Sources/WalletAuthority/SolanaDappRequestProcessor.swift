import WalletDomain
import WalletStorageSupport
// ∅ 2026 lil org

import Foundation

struct SolanaDappRequestProcessor {

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
                return .init(message: AuthorityStrings.somethingWentWrong, code: 4200)
            case .unauthorized(let publicKey):
                return .init(
                    message: AuthorityStrings.providerNotReady,
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
        catalog: WalletReviewCatalog?,
        solana: SolanaSigner = SolanaSigner(),
        endpoints: any SolanaEndpointResolving
    ) -> UnboundDappRequestPreparation {
        switch body.method {
        case .connect:
            return prepareConnect(request: request, body: body, catalog: catalog)
        case .signAllTransactions, .signMessage, .signTransaction, .signAndSendTransaction:
            if body.method == .signAllTransactions, body.messages == nil {
                return .immediate(immediateFailure(to: request, error: .malformedPayload))
            }
            guard let catalog else { return .needsCatalog }
            return prepareSigningOrSending(
                request: request,
                body: body,
                catalog: catalog,
                solana: solana,
                endpoints: endpoints
            )
        }
    }

    static func decodedSignMessage(
        _ message: String,
        messageEncoding: SafariRequest.Solana.MessageEncoding
    ) -> Data? {
        switch messageEncoding {
        case .hex:
            return WalletCrypto.hexData(string: message)
        case .utf8:
            return message.data(using: .utf8)
        }
    }

    private static func prepareConnect(
        request: SafariRequest,
        body: SafariRequest.Solana,
        catalog: WalletReviewCatalog?
    ) -> UnboundDappRequestPreparation {
        if let account = request.authorizedAccount, account.coin == .solana {
            return .immediate(.existingSolanaConnection)
        }
        if body.onlyIfTrusted {
            return .immediate(immediateFailure(to: request, error: .unauthorized(publicKey: body.publicKey)))
        }
        guard let catalog else { return .needsCatalog }
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
        catalog: WalletReviewCatalog,
        solana: SolanaSigner,
        endpoints: any SolanaEndpointResolving
    ) -> UnboundDappRequestPreparation {
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

        switch preparedSigningReviewContent(body: body, solana: solana) {
        case .success(let content):
            let capturedEndpoints: [Solana.Cluster: SolanaRPCEndpoint]
            switch content.payload {
            case .signature:
                capturedEndpoints = [:]
            case .solanaLegacyBroadcast, .solanaSerializedBroadcast:
                capturedEndpoints = Dictionary(uniqueKeysWithValues: Solana.Cluster.allCases.compactMap { cluster in
                    endpoints.endpoint(for: cluster).map { (cluster, $0) }
                })
                guard !capturedEndpoints.isEmpty else { return .unavailable }
            }
            return .approval(.approveMessage(SignMessageAction(
                subject: content.subject,
                walletId: walletID,
                account: account,
                meta: content.meta,
                payload: content.payload,
                solanaEndpoints: capturedEndpoints
            )))
        case .failure(let error):
            return .immediate(immediateFailure(to: request, error: error))
        }
    }

    private static func preparedSigningReviewContent(
        body: SafariRequest.Solana,
        solana: SolanaSigner
    ) -> Result<SigningReviewContent, ProviderError> {
        switch body.method {
        case .signAllTransactions:
            return signAllTransactionsReviewContent(body: body, solana: solana)
        case .signAndSendTransaction:
            return signAndSendReviewContent(body: body, solana: solana)
        case .signMessage, .signTransaction:
            return messageReviewContent(body: body, solana: solana)
        case .connect:
            return .failure(.internalError)
        }
    }

    private static func signAllTransactionsReviewContent(
        body: SafariRequest.Solana,
        solana: SolanaSigner
    ) -> Result<SigningReviewContent, ProviderError> {
        guard let messages = body.messages else {
            return .failure(.malformedPayload)
        }

        var preparedMessages = [SolanaPreparedTransactionMessage]()
        preparedMessages.reserveCapacity(messages.count)
        for message in messages {
            switch preparedTransactionMessage(message, publicKey: body.publicKey, solana: solana) {
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
                preparedMessages: preparedMessages, labels: summaryLabels
            ),
            payload: .signature(.solanaTransactions(preparedMessages))
        ))
    }

    private static func signAndSendReviewContent(
        body: SafariRequest.Solana,
        solana: SolanaSigner
    ) -> Result<SigningReviewContent, ProviderError> {
        let sendOptions: Solana.PreparedSendOptions
        switch SolanaSigner.preparedSendOptions(from: body.sendOptions) {
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

        return preparedLegacySignAndSendTransaction(body: body, solana: solana).map { transaction in
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
        body: SafariRequest.Solana,
        solana: SolanaSigner
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
                payload: .signature(.solanaMessage(messageData))
            ))
        case .signTransaction:
            return preparedTransactionMessage(
                canonicalMessage,
                publicKey: body.publicKey,
                solana: solana
            ).map { preparedMessage in
                SigningReviewContent(
                    subject: .approveTransaction,
                    meta: transactionApprovalMessage(
                        message: canonicalMessage,
                        preparedMessage: preparedMessage
                    ),
                    payload: .signature(.solanaTransaction(preparedMessage))
                )
            }
        case .connect, .signAllTransactions, .signAndSendTransaction:
            return .failure(.internalError)
        }
    }

    private static func preparedLegacySignAndSendTransaction(
        body: SafariRequest.Solana,
        solana: SolanaSigner
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
        publicKey: String,
        solana: SolanaSigner
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
                : SolanaTransactionSummaryFormatter.rawApprovalMessage(messages: [canonicalMessage], labels: summaryLabels)
        }
        guard let messageData = decodedMessageData ?? WalletCrypto.hexData(string: canonicalMessage),
              let messageText = String(data: messageData, encoding: .utf8),
              !messageText.isEmpty else {
            return canonicalMessage
        }
        return messageText
    }

    private static var summaryLabels: SolanaTransactionSummaryFormatter.Labels {
        .init(rawTransactionWarning: AuthorityStrings.rawSolanaTransactionWarning, data: AuthorityStrings.data)
    }

    private static func transactionApprovalMessage(
        message: String,
        preparedMessage: SolanaPreparedTransactionMessage
    ) -> String {
        return SolanaTransactionSummaryFormatter.approvalMessage(
            encodedMessages: [message],
            preparedMessages: [preparedMessage], labels: summaryLabels
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
                message: AuthorityStrings.transactionSubmissionStatusUnknown,
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
            return .init(message: AuthorityStrings.somethingWentWrong, code: 4200)
        case .invalidSendOptions:
            return .init(message: AuthorityStrings.unsupportedSolanaSendOptions, code: 4200)
        case .blockhashNotFound:
            return .init(message: AuthorityStrings.solanaBlockhashNotFound, code: -32003)
        case .confirmationFailed(let signature, let message, let code):
            return .init(
                message: message,
                code: code ?? -32005,
                context: .transactionSignature(signature)
            )
        case .confirmationTimedOut(let signature):
            return .init(
                message: AuthorityStrings.solanaConfirmationTimedOut,
                code: -32005,
                context: .transactionSignature(signature)
            )
        case .unsupportedMultiSignature:
            return .init(message: AuthorityStrings.failedToSend, code: 4200)
        case .rpcError(let message, let code):
            return .init(message: message, code: code ?? -32003)
        case .rpcUnavailable:
            return .internalError
        case .notSubmitted:
            return .init(
                message: AuthorityStrings.failedToSend,
                code: ProviderResponseError.internalErrorCode
            )
        case .unknown:
            return .init(message: AuthorityStrings.failedToSend, code: -32003)
        }
    }
}

