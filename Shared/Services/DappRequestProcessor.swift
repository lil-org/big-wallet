// ∅ 2026 lil org

import Foundation
import WalletCore

struct DappRequestProcessor {
    
    private static let walletsManager = WalletsManager.shared
    private static let ethereum = Ethereum.shared
    private static let solana = Solana.shared

    private struct PreparedSolanaSigningPayload {
        let messageData: Data
        let approvalSubject: ApprovalSubject
        let approvalMessage: String
    }

    private struct SolanaProviderResponseError {
        let message: String
        let code: Int
        let publicKey: String?
        let signature: String?

        init(message: String, code: Int, publicKey: String? = nil, signature: String? = nil) {
            self.message = message
            self.code = code
            self.publicKey = publicKey
            self.signature = signature
        }
    }

    private enum SolanaProviderError {
        case canceled
        case failedToSign
        case internalError
        case malformedPayload
        case unauthorized(publicKey: String)
        case sendTransaction(Solana.SendTransactionError)

        var responseError: SolanaProviderResponseError {
            switch self {
            case .canceled:
                return .init(message: Strings.canceled, code: 4001)
            case .failedToSign:
                return .init(message: Strings.failedToSign, code: -32603)
            case .internalError:
                return .init(message: Strings.somethingWentWrong, code: -32603)
            case .malformedPayload:
                return .init(message: Strings.somethingWentWrong, code: 4200)
            case .unauthorized(let publicKey):
                return .init(message: Strings.providerNotReady, code: 4100, publicKey: publicKey)
            case .sendTransaction(let error):
                switch error {
                case .invalidMessage:
                    return .init(message: Strings.somethingWentWrong, code: 4200)
                case .invalidSendOptions:
                    return .init(message: Strings.unsupportedSolanaSendOptions, code: 4200)
                case .blockhashNotFound:
                    return .init(message: Strings.solanaBlockhashNotFound, code: -32003)
                case .confirmationFailed(let signature, let message, let code):
                    return .init(message: message, code: code ?? -32005, signature: signature)
                case .confirmationTimedOut(let signature):
                    return .init(message: Strings.solanaConfirmationTimedOut, code: -32005, signature: signature)
                case .unsupportedMultiSignature:
                    return .init(message: Strings.failedToSend, code: 4200)
                case .rpcError(let message, let code):
                    return .init(message: message, code: code ?? -32003)
                case .unknown:
                    return .init(message: Strings.failedToSend, code: -32003)
                }
            }
        }
    }
    
    static func processSafariRequest(_ request: SafariRequest, completion: @escaping (String?) -> Void) -> DappRequestAction {
        if !ExtensionBridge.hasRequest(id: request.id) {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) {
                if !ExtensionBridge.hasRequest(id: request.id) {
                    if request.provider == .solana {
                        respond(to: request, solanaError: .internalError, completion: completion)
                    } else {
                        respond(to: request, error: Strings.somethingWentWrong, completion: completion)
                    }
                }
            }
        }
        
        switch request.body {
        case let .ethereum(body):
            return process(request: request, ethereumRequest: body, completion: completion)
        case let .solana(body):
            return process(request: request, solanaRequest: body, completion: completion)
        case let .unknown(body):
            switch body.method {
            case .justShowApp:
                ExtensionBridge.respond(response: ResponseToExtension(for: request))
                return .justShowApp
            case .switchAccount:
                let initiallyConnectedProviders = connectedProviders(in: body.providerConfigurations)
                let preselectedAccounts = preselectedAccounts(for: body.providerConfigurations)
                
                let chainId = body.providerConfigurations.compactMap { $0.chainId }.first
                let network = Networks.withChainIdHex(chainId)
                let action = SelectAccountAction(peer: request.peerMeta,
                                                 coinType: nil,
                                                 selectedAccounts: Set(preselectedAccounts),
                                                 initiallyConnectedProviders: initiallyConnectedProviders,
                                                 network: network,
                                                 source: .safariExtension) { chain, specificWalletAccounts in
                    guard let specificWalletAccounts else {
                        respond(to: request, error: Strings.canceled, completion: completion)
                        return
                    }

                    let resolvedChain = chain ?? network ?? Networks.ethereum
                    let specificProviderBodies = specificWalletAccounts.compactMap {
                        selectedAccountResponseBody(for: $0.account, chain: resolvedChain)
                    }
                    guard specificProviderBodies.count == specificWalletAccounts.count else {
                        respond(to: request, error: Strings.somethingWentWrong, completion: completion)
                        return
                    }

                    let providersToDisconnect = disconnectedProviders(initiallyConnectedProviders: initiallyConnectedProviders,
                                                                       selectedAccounts: specificWalletAccounts)
                    let body = ResponseToExtension.Multiple(bodies: specificProviderBodies, providersToDisconnect: Array(providersToDisconnect))
                    respond(to: request, body: .multiple(body), completion: completion)
                }
                return .switchAccount(action)
            }
        }
    }

    private static func process(request: SafariRequest, solanaRequest: SafariRequest.Solana, completion: @escaping (String?) -> Void) -> DappRequestAction {
        switch solanaRequest.method {
        case .connect:
            return processSolanaConnectRequest(request: request, completion: completion)
        case .signAllTransactions:
            return processSolanaSignAllTransactionsRequest(request: request,
                                                           solanaRequest: solanaRequest,
                                                           completion: completion)
        case .signMessage, .signTransaction, .signAndSendTransaction:
            return processSolanaSigningOrSendingRequest(request: request,
                                                        solanaRequest: solanaRequest,
                                                        completion: completion)
        }
    }

    private static func processSolanaConnectRequest(request: SafariRequest,
                                                    completion: @escaping (String?) -> Void) -> DappRequestAction {
        let action = SelectAccountAction(peer: request.peerMeta,
                                         coinType: .solana,
                                         selectedAccounts: Set(walletsManager.suggestedAccounts(coin: .solana)),
                                         initiallyConnectedProviders: Set(),
                                         network: nil,
                                         source: .safariExtension) { _, specificWalletAccounts in
            if let specificWalletAccount = specificWalletAccounts?.first,
               let responseBody = solanaResponseBody(for: specificWalletAccount.account) {
                respond(to: request, body: responseBody, completion: completion)
            } else {
                respond(to: request, solanaError: .canceled, completion: completion)
            }
        }
        return .selectAccount(action)
    }

    private static func processSolanaSignAllTransactionsRequest(request: SafariRequest,
                                                                solanaRequest: SafariRequest.Solana,
                                                                completion: @escaping (String?) -> Void) -> DappRequestAction {
        guard let messages = solanaRequest.messages else {
            respond(to: request, solanaError: .malformedPayload, completion: completion)
            return .none
        }
        guard let (wallet, account) = solanaWalletAndAccount(for: request,
                                                             publicKey: solanaRequest.publicKey,
                                                             completion: completion) else { return .none }

        var decodedMessages = [Data]()
        decodedMessages.reserveCapacity(messages.count)
        for message in messages {
            guard let decodedMessage = decodedSolanaTransactionMessage(message,
                                                                       publicKey: solanaRequest.publicKey,
                                                                       request: request,
                                                                       completion: completion)
            else { return .none }
            decodedMessages.append(decodedMessage)
        }

        let displayMessage = solanaTransactionApprovalMessage(messages: messages,
                                                              decodedMessages: decodedMessages)
        return solanaApprovalAction(request: request,
                                    wallet: wallet,
                                    account: account,
                                    subject: .approveTransaction,
                                    meta: displayMessage,
                                    completion: completion) { privateKey in
            let results = decodedMessages.compactMap { solana.sign(messageData: $0, privateKey: privateKey) }
            guard results.count == decodedMessages.count else {
                respond(to: request, solanaError: .failedToSign, completion: completion)
                return
            }

            respond(to: request, solanaResponse: .init(results: results), completion: completion)
        }
    }

    private static func processSolanaSigningOrSendingRequest(request: SafariRequest,
                                                             solanaRequest: SafariRequest.Solana,
                                                             completion: @escaping (String?) -> Void) -> DappRequestAction {
        guard let (wallet, account) = solanaWalletAndAccount(for: request,
                                                             publicKey: solanaRequest.publicKey,
                                                             completion: completion) else { return .none }

        switch solanaRequest.method {
        case .signAndSendTransaction:
            let preparedSendOptions: Solana.PreparedSendOptions
            switch Solana.preparedSendOptions(from: solanaRequest.sendOptions) {
            case .failure(let error):
                respond(to: request, solanaError: .sendTransaction(error), completion: completion)
                return .none
            case .success(let value):
                preparedSendOptions = value
            }

            let clusterSelection = SolanaClusterSelection(selectedCluster: preparedSendOptions.clusterHint,
                                                          suggestedCluster: preparedSendOptions.clusterHint)
            if let serializedTransaction = solanaRequest.transaction {
                return processSerializedSolanaSignAndSendRequest(request: request,
                                                                 solanaRequest: solanaRequest,
                                                                 serializedTransaction: serializedTransaction,
                                                                 sendOptions: preparedSendOptions,
                                                                 clusterSelection: clusterSelection,
                                                                 wallet: wallet,
                                                                 account: account,
                                                                 completion: completion)
            }

            guard let preparedLegacyTransaction = preparedLegacySolanaSignAndSendTransaction(request: request,
                                                                                            solanaRequest: solanaRequest,
                                                                                            completion: completion) else {
                return .none
            }

            return solanaApprovalAction(request: request,
                                        wallet: wallet,
                                        account: account,
                                        subject: .approveTransaction,
                                        meta: solanaTransactionApprovalMessage(message: preparedLegacyTransaction.approvalMessage,
                                                                               messageData: preparedLegacyTransaction.messageData),
                                        clusterSelection: clusterSelection,
                                        completion: completion) { selectedCluster, privateKey in
                signAndSendSolanaTransaction(request: request,
                                             preparedLegacyTransaction: preparedLegacyTransaction,
                                             cluster: selectedCluster,
                                             sendOptions: preparedSendOptions,
                                             privateKey: privateKey,
                                             completion: completion)
            }
        case .signMessage, .signTransaction:
            guard let preparedSigningPayload = preparedSolanaSigningPayload(for: request,
                                                                            solanaRequest: solanaRequest,
                                                                            completion: completion) else {
                return .none
            }

            return solanaApprovalAction(request: request,
                                        wallet: wallet,
                                        account: account,
                                        subject: preparedSigningPayload.approvalSubject,
                                        meta: preparedSigningPayload.approvalMessage,
                                        completion: completion) { privateKey in
                guard let signed = solana.sign(messageData: preparedSigningPayload.messageData,
                                               privateKey: privateKey) else {
                    respond(to: request, solanaError: .failedToSign, completion: completion)
                    return
                }

                respond(to: request, solanaResponse: .init(result: signed), completion: completion)
            }
        case .connect, .signAllTransactions:
            respond(to: request, solanaError: .internalError, completion: completion)
            return .none
        }
    }

    private static func preparedSolanaSigningPayload(for request: SafariRequest,
                                                     solanaRequest: SafariRequest.Solana,
                                                     completion: @escaping (String?) -> Void) -> PreparedSolanaSigningPayload? {
        guard let canonicalMessage = requiredSolanaMessage(for: request,
                                                           solanaRequest: solanaRequest,
                                                           completion: completion) else { return nil }

        switch solanaRequest.method {
        case .signMessage:
            guard let signMessageEncoding = solanaRequest.signMessageEncoding,
                  let messageData = decodedSolanaSignMessage(canonicalMessage,
                                                             messageEncoding: signMessageEncoding) else {
                respond(to: request, solanaError: .malformedPayload, completion: completion)
                return nil
            }

            return PreparedSolanaSigningPayload(messageData: messageData,
                                                approvalSubject: .signMessage,
                                                approvalMessage: approvalMessage(for: solanaRequest,
                                                                                 canonicalMessage: canonicalMessage,
                                                                                 decodedMessageData: messageData))
        case .signTransaction:
            guard let messageData = decodedSolanaTransactionMessage(canonicalMessage,
                                                                    publicKey: solanaRequest.publicKey,
                                                                    request: request,
                                                                    completion: completion)
            else { return nil }

            return PreparedSolanaSigningPayload(messageData: messageData,
                                                approvalSubject: .approveTransaction,
                                                approvalMessage: solanaTransactionApprovalMessage(message: canonicalMessage,
                                                                                                  messageData: messageData))
        case .connect, .signAllTransactions, .signAndSendTransaction:
            respond(to: request, solanaError: .internalError, completion: completion)
            return nil
        }
    }

    private static func processSerializedSolanaSignAndSendRequest(request: SafariRequest,
                                                                  solanaRequest: SafariRequest.Solana,
                                                                  serializedTransaction: String,
                                                                  sendOptions: Solana.PreparedSendOptions,
                                                                  clusterSelection: SolanaClusterSelection,
                                                                  wallet: WalletContainer,
                                                                  account: Account,
                                                                  completion: @escaping (String?) -> Void) -> DappRequestAction {
        switch solana.preparedSerializedTransactionForSignAndSend(serializedTransaction: serializedTransaction,
                                                                  publicKey: solanaRequest.publicKey) {
        case .failure(let error):
            respond(to: request, solanaError: .sendTransaction(error), completion: completion)
            return .none
        case .success(let preparedSerializedTransaction):
            return solanaApprovalAction(request: request,
                                        wallet: wallet,
                                        account: account,
                                        subject: .approveTransaction,
                                        meta: solanaTransactionApprovalMessage(message: preparedSerializedTransaction.approvalMessage,
                                                                               messageData: preparedSerializedTransaction.messageData),
                                        clusterSelection: clusterSelection,
                                        completion: completion) { selectedCluster, privateKey in
                signAndSendSolanaTransaction(request: request,
                                             preparedSerializedTransaction: preparedSerializedTransaction,
                                             cluster: selectedCluster,
                                             sendOptions: sendOptions,
                                             privateKey: privateKey,
                                             completion: completion)
            }
        }
    }

    private static func preparedLegacySolanaSignAndSendTransaction(request: SafariRequest,
                                                                   solanaRequest: SafariRequest.Solana,
                                                                   completion: @escaping (String?) -> Void) -> Solana.PreparedLegacySignAndSendTransaction? {
        guard let message = requiredSolanaMessage(for: request,
                                                  solanaRequest: solanaRequest,
                                                  completion: completion) else { return nil }

        switch solana.preparedLegacySignAndSendTransaction(message: message,
                                                           publicKey: solanaRequest.publicKey) {
        case .failure(let error):
            respond(to: request, solanaError: .sendTransaction(error), completion: completion)
            return nil
        case .success(let preparedLegacyTransaction):
            return preparedLegacyTransaction
        }
    }

    private static func requiredSolanaMessage(for request: SafariRequest,
                                              solanaRequest: SafariRequest.Solana,
                                              completion: @escaping (String?) -> Void) -> String? {
        guard let message = solanaRequest.message else {
            respond(to: request, solanaError: .malformedPayload, completion: completion)
            return nil
        }
        return message
    }

    private static func decodedSolanaTransactionMessage(_ message: String,
                                                        publicKey: String,
                                                        request: SafariRequest,
                                                        completion: @escaping (String?) -> Void) -> Data? {
        guard let messageData = solana.decodeMessage(message, asHex: false) else {
            respond(to: request, solanaError: .sendTransaction(.invalidMessage), completion: completion)
            return nil
        }

        if let validationError = solana.validationErrorForSigningTransaction(messageData: messageData,
                                                                             publicKey: publicKey) {
            respond(to: request, solanaError: .sendTransaction(validationError), completion: completion)
            return nil
        }

        return messageData
    }

    static func decodedSolanaSignMessage(_ message: String,
                                         messageEncoding: SafariRequest.Solana.MessageEncoding) -> Data? {
        switch messageEncoding {
        case .hex:
            return solana.decodeMessage(message, asHex: true)
        case .utf8:
            return message.data(using: .utf8)
        }
    }

    private static func approvalMessage(for solanaRequest: SafariRequest.Solana,
                                        canonicalMessage: String,
                                        decodedMessageData: Data? = nil) -> String {
        if solanaRequest.method == .signMessage {
            if solanaRequest.displayHex {
                return canonicalMessage
            }

            guard let messageData = decodedMessageData ?? solana.decodeMessage(canonicalMessage, asHex: true),
                  let messageText = String(data: messageData, encoding: .utf8),
                  !messageText.isEmpty
            else {
                return canonicalMessage
            }

            return messageText
        } else {
            return SolanaTransactionSummaryFormatter.rawApprovalMessage(messages: [canonicalMessage])
        }
    }

    private static func solanaTransactionApprovalMessage(message: String, messageData: Data) -> String {
        return SolanaTransactionSummaryFormatter.approvalMessage(messageData: messageData,
                                                                 encodedMessages: [message])
    }

    private static func solanaTransactionApprovalMessage(messages: [String], decodedMessages: [Data]) -> String {
        return SolanaTransactionSummaryFormatter.approvalMessage(encodedMessages: messages,
                                                                 messageDataList: decodedMessages)
    }

    private static func solanaApprovalAction(request: SafariRequest,
                                             wallet: WalletContainer,
                                             account: Account,
                                             subject: ApprovalSubject,
                                             meta: String,
                                             clusterSelection: SolanaClusterSelection,
                                             completion: @escaping (String?) -> Void,
                                             onApprove: @escaping (Solana.Cluster, PrivateKey) -> Void) -> DappRequestAction {
        return solanaApprovalAction(request: request,
                                    wallet: wallet,
                                    account: account,
                                    subject: subject,
                                    meta: meta,
                                    solanaClusterSelection: clusterSelection,
                                    completion: completion) { privateKey in
            guard let selectedCluster = clusterSelection.selectedCluster else {
                respond(to: request, solanaError: .internalError, completion: completion)
                return
            }

            onApprove(selectedCluster, privateKey)
        }
    }

    private static func signAndSendSolanaTransaction(request: SafariRequest,
                                                     preparedSerializedTransaction: Solana.PreparedSerializedTransaction,
                                                     cluster: Solana.Cluster,
                                                     sendOptions: Solana.PreparedSendOptions,
                                                     privateKey: PrivateKey,
                                                     completion: @escaping (String?) -> Void) {
        solana.signAndSendTransaction(preparedSerializedTransaction: preparedSerializedTransaction,
                                      cluster: cluster,
                                      sendOptions: sendOptions,
                                      privateKey: privateKey,
                                      completion: solanaSendTransactionResultHandler(request: request,
                                                                                     completion: completion))
    }

    private static func signAndSendSolanaTransaction(request: SafariRequest,
                                                     preparedLegacyTransaction: Solana.PreparedLegacySignAndSendTransaction,
                                                     cluster: Solana.Cluster,
                                                     sendOptions: Solana.PreparedSendOptions,
                                                     privateKey: PrivateKey,
                                                     completion: @escaping (String?) -> Void) {
        solana.signAndSendTransaction(preparedLegacyTransaction: preparedLegacyTransaction,
                                      cluster: cluster,
                                      sendOptions: sendOptions,
                                      privateKey: privateKey,
                                      completion: solanaSendTransactionResultHandler(request: request,
                                                                                     completion: completion))
    }

    private static func solanaSendTransactionResultHandler(request: SafariRequest,
                                                           completion: @escaping (String?) -> Void) -> (Result<String, Solana.SendTransactionError>) -> Void {
        return { result in
            switch result {
            case .success(let signature):
                respond(to: request, solanaResponse: .init(result: signature), completion: completion)
            case .failure(let error):
                respond(to: request, solanaError: .sendTransaction(error), completion: completion)
            }
        }
    }

    private static func solanaWalletAndAccount(for request: SafariRequest,
                                               publicKey: String,
                                               completion: @escaping (String?) -> Void) -> (WalletContainer, Account)? {
        guard let walletAndAccount = walletsManager.getWalletAndAccount(coin: .solana, address: publicKey) else {
            respond(to: request, solanaError: .unauthorized(publicKey: publicKey), completion: completion)
            return nil
        }
        return walletAndAccount
    }

    private static func solanaApprovalAction(request: SafariRequest,
                                             wallet: WalletContainer,
                                             account: Account,
                                             subject: ApprovalSubject,
                                             meta: String,
                                             solanaClusterSelection: SolanaClusterSelection? = nil,
                                             completion: @escaping (String?) -> Void,
                                             onApprove: @escaping (PrivateKey) -> Void) -> DappRequestAction {
        let action = SignMessageAction(provider: request.provider,
                                       subject: subject,
                                       walletId: wallet.id,
                                       account: account,
                                       meta: meta,
                                       peerMeta: request.peerMeta,
                                       solanaClusterSelection: solanaClusterSelection) { approved in
            guard approved else {
                respond(to: request, solanaError: .canceled, completion: completion)
                return
            }

            guard let privateKey = walletsManager.getPrivateKey(wallet: wallet, account: account) else {
                respond(to: request, solanaError: .failedToSign, completion: completion)
                return
            }

            onApprove(privateKey)
        }
        return .approveMessage(action)
    }

    private static func process(request: SafariRequest, ethereumRequest: SafariRequest.Ethereum, completion: @escaping (String?) -> Void) -> DappRequestAction {
        let peerMeta = request.peerMeta
        lazy var walletAndAccount = walletsManager.getWalletAndAccount(coin: .ethereum, address: ethereumRequest.address)
        lazy var privateKey = walletsManager.getPrivateKey(coin: .ethereum, address: ethereumRequest.address)
        
        switch ethereumRequest.method {
        case .addEthereumChain:
            if let chainToAdd = EthereumNetworkFromDapp.from(ethereumRequest.parameters) {
                if let chainId = Int(hexString: chainToAdd.chainId), Nodes.knowsNode(chainId: chainId) {
                    let responseBody = ResponseToExtension.Ethereum(results: [ethereumRequest.address], chainId: chainToAdd.chainId)
                    respond(to: request, body: .ethereum(responseBody), completion: completion)
                } else {
                    let action = AddEthereumChainAction(chainToAdd: chainToAdd) { didApprove in
                        if didApprove {
                            Networks.add(networkFromDapp: chainToAdd)
                            let responseBody = ResponseToExtension.Ethereum(results: [ethereumRequest.address], chainId: chainToAdd.chainId)
                            respond(to: request, body: .ethereum(responseBody), completion: completion)
                        } else {
                            respond(to: request, error: Strings.canceled, completion: completion)
                        }
                    }
                    return .addEthereumChain(action)
                }
            } else {
                respond(to: request, error: Strings.somethingWentWrong, completion: completion)
            }
        case .requestAccounts:
            let action = SelectAccountAction(peer: peerMeta,
                                             coinType: .ethereum,
                                             selectedAccounts: Set(walletsManager.suggestedAccounts(coin: .ethereum)),
                                             initiallyConnectedProviders: Set(),
                                             network: nil,
                                             source: .safariExtension) { chain, specificWalletAccounts in
                if let chain = chain,
                   let specificWalletAccount = specificWalletAccounts?.first,
                   let responseBody = ethereumResponseBody(for: specificWalletAccount.account, chain: chain) {
                    respond(to: request, body: responseBody, completion: completion)
                } else {
                    respond(to: request, error: Strings.canceled, completion: completion)
                }
            }
            return .selectAccount(action)
        case .signTypedMessage:
            if let walletAndAccount = walletAndAccount,
               let raw = ethereumRequest.raw,
               let privateKey = privateKey {
                let action = SignMessageAction(provider: request.provider, subject: .signTypedData, walletId: walletAndAccount.0.id, account: walletAndAccount.1, meta: raw, peerMeta: peerMeta) { approved in
                    if approved {
                        signTypedData(privateKey: privateKey, raw: raw, request: request, completion: completion)
                    } else {
                        respond(to: request, error: Strings.failedToSign, completion: completion)
                    }
                }
                return .approveMessage(action)
            } else {
                respond(to: request, error: Strings.somethingWentWrong, completion: completion)
            }
        case .signMessage:
            if let data = ethereumRequest.message,
               let walletAndAccount = walletAndAccount,
               let privateKey = privateKey {
                let action = SignMessageAction(provider: request.provider, subject: .signMessage, walletId: walletAndAccount.0.id, account: walletAndAccount.1, meta: data.hexString, peerMeta: peerMeta) { approved in
                    if approved {
                        signMessage(privateKey: privateKey, data: data, request: request, completion: completion)
                    } else {
                        respond(to: request, error: Strings.failedToSign, completion: completion)
                    }
                }
                return .approveMessage(action)
            } else {
                respond(to: request, error: Strings.somethingWentWrong, completion: completion)
            }
        case .signPersonalMessage:
            if let data = ethereumRequest.message,
               let walletAndAccount = walletAndAccount,
               let privateKey = privateKey {
                let text = String(data: data, encoding: .utf8) ?? data.hexString
                let action = SignMessageAction(provider: request.provider, subject: .signPersonalMessage, walletId: walletAndAccount.0.id, account: walletAndAccount.1, meta: text, peerMeta: peerMeta) { approved in
                    if approved {
                        signPersonalMessage(privateKey: privateKey, data: data, request: request, completion: completion)
                    } else {
                        respond(to: request, error: Strings.failedToSign, completion: completion)
                    }
                }
                return .approveMessage(action)
            } else {
                respond(to: request, error: Strings.somethingWentWrong, completion: completion)
            }
        case .signTransaction:
            if let transaction = ethereumRequest.transaction,
               let chainId = ethereumRequest.currentChainId,
               let chain = Networks.withChainId(chainId),
               let walletAndAccount = walletAndAccount,
               let privateKey = privateKey {
                let action = SendTransactionAction(provider: request.provider,
                                                   transaction: transaction,
                                                   chain: chain, walletId: walletAndAccount.0.id,
                                                   account: walletAndAccount.1,
                                                   peerMeta: peerMeta) { transaction in
                    if let transaction = transaction {
                        sendTransaction(privateKey: privateKey, transaction: transaction, network: chain, respondTo: request, completion: completion)
                    } else {
                        respond(to: request, error: Strings.canceled, completion: completion)
                    }
                }
                return .approveTransaction(action)
            } else {
                respond(to: request, error: Strings.somethingWentWrong, completion: completion)
            }
        case .ecRecover:
            if let (signature, message) = ethereumRequest.signatureAndMessage,
               let recovered = ethereum.recover(signature: signature, message: message) {
                respond(to: request, body: .ethereum(.init(result: recovered)), completion: completion)
            } else {
                respond(to: request, error: Strings.failedToVerify, completion: completion)
            }
        case .switchEthereumChain, .watchAsset:
            respond(to: request, error: Strings.somethingWentWrong, completion: completion)
        }
        return .none
    }
    
    private static func signTypedData(privateKey: PrivateKey, raw: String, request: SafariRequest, completion: (String?) -> Void) {
        if let signed = try? ethereum.sign(typedData: raw, privateKey: privateKey) {
            respond(to: request, body: .ethereum(.init(result: signed)), completion: completion)
        } else {
            respond(to: request, error: Strings.failedToSign, completion: completion)
        }
    }
    
    private static func signMessage(privateKey: PrivateKey, data: Data, request: SafariRequest, completion: (String?) -> Void) {
        if let signed = try? ethereum.sign(data: data, privateKey: privateKey) {
            respond(to: request, body: .ethereum(.init(result: signed)), completion: completion)
        } else {
            respond(to: request, error: Strings.failedToSign, completion: completion)
        }
    }
    
    private static func signPersonalMessage(privateKey: PrivateKey, data: Data, request: SafariRequest, completion: (String?) -> Void) {
        if let signed = try? ethereum.signPersonalMessage(data: data, privateKey: privateKey) {
            respond(to: request, body: .ethereum(.init(result: signed)), completion: completion)
        } else {
            respond(to: request, error: Strings.failedToSign, completion: completion)
        }
    }
     
    private static func sendTransaction(privateKey: PrivateKey, transaction: Transaction, network: EthereumNetwork, respondTo: SafariRequest?, completion: @escaping (String?) -> Void) {
        ethereum.send(transaction: transaction, privateKey: privateKey, network: network) { hash in
            if let request = respondTo {
                if let hash = hash {
                    DappRequestProcessor.respond(to: request, body: .ethereum(.init(result: hash)), completion: completion)
                } else {
                    respond(to: request, error: Strings.failedToSend, completion: completion)
                }
            } else {
                completion(hash)
            }
        }
    }

    private static func selectedAccountResponseBody(for account: Account, chain: EthereumNetwork) -> ResponseToExtension.Body? {
        if let responseBody = ethereumResponseBody(for: account, chain: chain) {
            return responseBody
        }
        return solanaResponseBody(for: account)
    }

    private static func ethereumResponseBody(for account: Account, chain: EthereumNetwork) -> ResponseToExtension.Body? {
        guard account.coin == .ethereum else { return nil }
        let responseBody = ResponseToExtension.Ethereum(results: [account.address], chainId: chain.chainIdHexString)
        return .ethereum(responseBody)
    }

    private static func solanaResponseBody(for account: Account) -> ResponseToExtension.Body? {
        guard account.coin == .solana else { return nil }
        let responseBody = ResponseToExtension.Solana(publicKey: account.address)
        return .solana(responseBody)
    }

    private static func preselectedAccounts(for providerConfigurations: [SafariRequest.Unknown.ProviderConfiguration]) -> [SpecificWalletAccount] {
        return preselectedAccounts(for: providerConfigurations,
                                   accountForConfiguration: { configuration in
            guard let coin = CoinType.correspondingToInpageProvider(configuration.provider),
                  let address = configuration.address,
                  !address.isEmpty
            else { return nil }
            return walletsManager.getSpecificAccount(coin: coin, address: address)
        }, suggestedAccountsForProviders: { providers in
            walletsManager.suggestedAccounts(providers: providers)
        }, defaultSuggestedAccounts: {
            walletsManager.suggestedAccounts()
        })
    }

    static func preselectedAccounts(for providerConfigurations: [SafariRequest.Unknown.ProviderConfiguration],
                                    accountForConfiguration: (SafariRequest.Unknown.ProviderConfiguration) -> SpecificWalletAccount?,
                                    suggestedAccountsForProviders: (Set<InpageProvider>) -> [SpecificWalletAccount],
                                    defaultSuggestedAccounts: () -> [SpecificWalletAccount]) -> [SpecificWalletAccount] {
        return preselectedAccounts(for: providerConfigurations,
                                   accountForConfiguration: accountForConfiguration,
                                   suggestedValuesForProviders: suggestedAccountsForProviders,
                                   defaultSuggestedValues: defaultSuggestedAccounts)
    }

    static func preselectedAccounts<Value>(for providerConfigurations: [SafariRequest.Unknown.ProviderConfiguration],
                                           accountForConfiguration: (SafariRequest.Unknown.ProviderConfiguration) -> Value?,
                                           suggestedValuesForProviders: (Set<InpageProvider>) -> [Value],
                                           defaultSuggestedValues: () -> [Value]) -> [Value] {
        let connectedProviders = connectedProviders(in: providerConfigurations)
        guard !connectedProviders.isEmpty else { return defaultSuggestedValues() }

        var preselectedValues = [Value]()
        var resolvedProviders = Set<InpageProvider>()
        for configuration in providerConfigurations {
            guard !resolvedProviders.contains(configuration.provider),
                  CoinType.correspondingToInpageProvider(configuration.provider) != nil,
                  let value = accountForConfiguration(configuration)
            else { continue }

            preselectedValues.append(value)
            resolvedProviders.insert(configuration.provider)
        }

        let missingProviders = connectedProviders.subtracting(resolvedProviders)
        guard !missingProviders.isEmpty else { return preselectedValues }

        return preselectedValues + suggestedValuesForProviders(missingProviders)
    }

    private static func disconnectedProviders(initiallyConnectedProviders: Set<InpageProvider>,
                                              selectedAccounts: [SpecificWalletAccount]) -> Set<InpageProvider> {
        let selectedCoins = Set(selectedAccounts.map { $0.account.coin })
        return initiallyConnectedProviders.filter { provider in
            guard let coin = CoinType.correspondingToInpageProvider(provider) else {
                return true
            }
            return !selectedCoins.contains(coin)
        }
    }

    private static func connectedProviders(in providerConfigurations: [SafariRequest.Unknown.ProviderConfiguration]) -> Set<InpageProvider> {
        return Set(providerConfigurations.map { $0.provider }.filter { provider in
            CoinType.correspondingToInpageProvider(provider) != nil
        })
    }

    private static func respond(to safariRequest: SafariRequest, solanaResponse: ResponseToExtension.Solana, completion: (String?) -> Void) {
        respond(to: safariRequest, body: .solana(solanaResponse), completion: completion)
    }

    private static func respond(to safariRequest: SafariRequest, body: ResponseToExtension.Body, completion: (String?) -> Void) {
        let response = ResponseToExtension(for: safariRequest, body: body)
        sendResponse(response, completion: completion)
    }

    private static func respond(to safariRequest: SafariRequest, solanaError: SolanaProviderError, completion: (String?) -> Void) {
        let responseError = solanaError.responseError
        respond(to: safariRequest,
                error: responseError.message,
                errorCode: responseError.code,
                errorPublicKey: responseError.publicKey,
                errorSignature: responseError.signature,
                completion: completion)
    }
    
    private static func respond(to safariRequest: SafariRequest,
                                error: String,
                                errorCode: Int? = nil,
                                errorPublicKey: String? = nil,
                                errorSignature: String? = nil,
                                completion: (String?) -> Void) {
        let response = ResponseToExtension(for: safariRequest,
                                           error: error,
                                           errorCode: errorCode,
                                           errorPublicKey: errorPublicKey,
                                           errorSignature: errorSignature)
        sendResponse(response, completion: completion)
    }
    
    private static func sendResponse(_ response: ResponseToExtension, completion: (String?) -> Void) {
        ExtensionBridge.respond(response: response)
        completion(nil)
    }
    
}
