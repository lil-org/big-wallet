// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import WalletCore

struct DappRequestProcessor {
    
    private static let walletsManager = WalletsManager.shared
    private static let ethereum = Ethereum.shared
    private static let solana = Solana.shared
    
    static func processSafariRequest(_ request: SafariRequest, completion: @escaping () -> Void) -> DappRequestAction {
        guard ExtensionBridge.hasRequest(id: request.id) else {
            respond(to: request, error: Strings.somethingWentWrong, completion: completion)
            return .none
        }
        
        switch request.body {
        case let .ethereum(body):
            return process(request: request, ethereumRequest: body, completion: completion)
        case let .solana(body):
            return process(request: request, solanaRequest: body, completion: completion)
        case .tezos:
            respond(to: request, error: "Tezos is not supported yet", completion: completion)
            return .none
        case let .unknown(body):
            switch body.method {
            case .justShowApp:
                ExtensionBridge.respond(response: ResponseToExtension(for: request))
                return .justShowApp
            case .switchAccount:
                let action = SelectAccountAction(provider: .unknown) { chain, _, account in
                    if let chain = chain, let account = account {
                        if account.coin == .ethereum {
                            let responseBody = ResponseToExtension.Ethereum(results: [account.address], chainId: chain.hexStringId, rpcURL: chain.nodeURLString)
                            respond(to: request, body: .ethereum(responseBody), completion: completion)
                        } else {
                            let responseBody = ResponseToExtension.Solana(publicKey: account.address)
                            respond(to: request, body: .solana(responseBody), completion: completion)
                        }
                    } else {
                        respond(to: request, error: Strings.canceled, completion: completion)
                    }
                }
                return .selectAccount(action)
            }
        }
    }
    
    private static func process(request: SafariRequest, solanaRequest body: SafariRequest.Solana, completion: @escaping () -> Void) -> DappRequestAction {
        let peerMeta = PeerMeta(title: request.host, iconURLString: request.favicon)
        
        func getAccount() -> Account? {
            return walletsManager.wallets.flatMap { $0.accounts }.first(where: { $0.address == body.publicKey })
        }
        
        func getPrivateKey() -> WalletCore.PrivateKey? {
            guard let password = Keychain.shared.password else { return nil }
            for wallet in walletsManager.wallets {
                if let account = wallet.accounts.first(where: { $0.address == body.publicKey }) {
                    return try? wallet.privateKey(password: password, account: account)
                }
            }
            return nil
        }
        
        switch body.method {
        case .connect:
            let action = SelectAccountAction(provider: .solana) { _, _, account in
                if let account = account, account.coin == .solana {
                    let responseBody = ResponseToExtension.Solana(publicKey: account.address)
                    respond(to: request, body: .solana(responseBody), completion: completion)
                } else {
                    respond(to: request, error: Strings.canceled, completion: completion)
                }
            }
            return .selectAccount(action)
        case .signAllTransactions:
            guard let messages = body.messages, let account = getAccount() else {
                respond(to: request, error: Strings.somethingWentWrong, completion: completion)
                return .none
            }
            let displayMessage = messages.joined(separator: "\n\n")
            let action = SignMessageAction(provider: request.provider, subject: .approveTransaction, account: account, meta: displayMessage, peerMeta: peerMeta) { approved in
                if approved, let privateKey = getPrivateKey() {
                    var results = [String]()
                    for message in messages {
                        guard let signed = solana.sign(message: message, asHex: false, privateKey: privateKey) else {
                            respond(to: request, error: Strings.failedToSign, completion: completion)
                            return
                        }
                        results.append(signed)
                    }
                    let responseBody = ResponseToExtension.Solana(results: results)
                    respond(to: request, body: .solana(responseBody), completion: completion)
                } else {
                    respond(to: request, error: Strings.failedToSign, completion: completion)
                }
            }
            return .approveMessage(action)
        case .signMessage, .signTransaction, .signAndSendTransaction:
            guard let message = body.message, let account = getAccount() else {
                respond(to: request, error: Strings.somethingWentWrong, completion: completion)
                return .none
            }
            let displayMessage: String
            let subject: ApprovalSubject
            switch body.method {
            case .signMessage:
                displayMessage = body.displayHex ? message : (String(data: Data(hex: message), encoding: .utf8) ?? message)
                subject = .signMessage
            default:
                displayMessage = message
                subject = .approveTransaction
            }
            let action = SignMessageAction(provider: request.provider, subject: subject, account: account, meta: displayMessage, peerMeta: peerMeta) { approved in
                guard approved, let privateKey = getPrivateKey() else {
                    respond(to: request, error: Strings.failedToSign, completion: completion)
                    return
                }
                
                if body.method == .signAndSendTransaction {
                    solana.signAndSendTransaction(message: message, options: body.sendOptions, privateKey: privateKey) { result in
                        switch result {
                        case let .success(signature):
                            let responseBody = ResponseToExtension.Solana(result: signature)
                            respond(to: request, body: .solana(responseBody), completion: completion)
                        case .failure:
                            respond(to: request, error: Strings.failedToSend, completion: completion)
                        }
                    }
                } else if let signed = solana.sign(message: message, asHex: body.method == .signMessage, privateKey: privateKey) {
                    let responseBody = ResponseToExtension.Solana(result: signed)
                    respond(to: request, body: .solana(responseBody), completion: completion)
                } else {
                    respond(to: request, error: Strings.failedToSign, completion: completion)
                }
            }
            return .approveMessage(action)
        }
    }
    
    private static func process(request: SafariRequest, ethereumRequest: SafariRequest.Ethereum, completion: @escaping () -> Void) -> DappRequestAction {
        let peerMeta = PeerMeta(title: request.host, iconURLString: request.favicon)
        
        func getAccount() -> Account? {
            return walletsManager.wallets.flatMap { $0.accounts }.first(where: { $0.address.lowercased() == ethereumRequest.address.lowercased() })
        }
        
        switch ethereumRequest.method {
        case .switchAccount, .requestAccounts:
            let action = SelectAccountAction(provider: .ethereum) { chain, wallet, account in
                if let chain = chain, let address = wallet?.ethereumAddress, account?.coin == .ethereum {
                    let responseBody = ResponseToExtension.Ethereum(results: [address], chainId: chain.hexStringId, rpcURL: chain.nodeURLString)
                    respond(to: request, body: .ethereum(responseBody), completion: completion)
                } else {
                    respond(to: request, error: Strings.canceled, completion: completion)
                }
            }
            return .selectAccount(action)
        case .signTypedMessage:
            if let raw = ethereumRequest.raw,
               let wallet = walletsManager.getWallet(address: ethereumRequest.address),
               let account = getAccount() {
                let action = SignMessageAction(provider: request.provider, subject: .signTypedData, account: account, meta: raw, peerMeta: peerMeta) { approved in
                    if approved {
                        signTypedData(wallet: wallet, raw: raw, request: request, completion: completion)
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
               let wallet = walletsManager.getWallet(address: ethereumRequest.address),
               let account = getAccount() {
                let action = SignMessageAction(provider: request.provider, subject: .signMessage, account: account, meta: data.hexString, peerMeta: peerMeta) { approved in
                    if approved {
                        signMessage(wallet: wallet, data: data, request: request, completion: completion)
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
               let wallet = walletsManager.getWallet(address: ethereumRequest.address),
               let account = getAccount() {
                let text = String(data: data, encoding: .utf8) ?? data.hexString
                let action = SignMessageAction(provider: request.provider, subject: .signPersonalMessage, account: account, meta: text, peerMeta: peerMeta) { approved in
                    if approved {
                        signPersonalMessage(wallet: wallet, data: data, request: request, completion: completion)
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
               let chain = ethereumRequest.chain,
               let wallet = walletsManager.getWallet(address: ethereumRequest.address),
               let account = getAccount() {
                let action = SendTransactionAction(provider: request.provider,
                                                   transaction: transaction,
                                                   chain: chain,
                                                   account: account,
                                                   peerMeta: peerMeta) { transaction in
                    if let transaction = transaction {
                        sendTransaction(wallet: wallet, transaction: transaction, chain: chain, request: request, completion: completion)
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
        case .addEthereumChain, .switchEthereumChain, .watchAsset:
            respond(to: request, error: Strings.somethingWentWrong, completion: completion)
        }
        return .none
    }
    
    private static func signTypedData(wallet: TokenaryWallet, raw: String, request: SafariRequest, completion: () -> Void) {
        if let signed = try? ethereum.sign(typedData: raw, wallet: wallet) {
            respond(to: request, body: .ethereum(.init(result: signed)), completion: completion)
        } else {
            respond(to: request, error: Strings.failedToSign, completion: completion)
        }
    }
    
    private static func signMessage(wallet: TokenaryWallet, data: Data, request: SafariRequest, completion: () -> Void) {
        if let signed = try? ethereum.sign(data: data, wallet: wallet) {
            respond(to: request, body: .ethereum(.init(result: signed)), completion: completion)
        } else {
            respond(to: request, error: Strings.failedToSign, completion: completion)
        }
    }
    
    private static func signPersonalMessage(wallet: TokenaryWallet, data: Data, request: SafariRequest, completion: () -> Void) {
        if let signed = try? ethereum.signPersonalMessage(data: data, wallet: wallet) {
            respond(to: request, body: .ethereum(.init(result: signed)), completion: completion)
        } else {
            respond(to: request, error: Strings.failedToSign, completion: completion)
        }
    }
    
    private static func sendTransaction(wallet: TokenaryWallet, transaction: Transaction, chain: EthereumChain, request: SafariRequest, completion: () -> Void) {
        if let transactionHash = try? ethereum.send(transaction: transaction, wallet: wallet, chain: chain) {
            DappRequestProcessor.respond(to: request, body: .ethereum(.init(result: transactionHash)), completion: completion)
        } else {
            respond(to: request, error: Strings.failedToSend, completion: completion)
        }
    }
    
    private static func respond(to safariRequest: SafariRequest, body: ResponseToExtension.Body, completion: () -> Void) {
        let response = ResponseToExtension(for: safariRequest, body: body)
        sendResponse(response, completion: completion)
    }
    
    private static func respond(to safariRequest: SafariRequest, error: String, completion: () -> Void) {
        let response = ResponseToExtension(for: safariRequest, error: error)
        sendResponse(response, completion: completion)
    }
    
    private static func sendResponse(_ response: ResponseToExtension, completion: () -> Void) {
        ExtensionBridge.respond(response: response)
        completion()
    }
    
}
