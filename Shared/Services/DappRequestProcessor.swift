// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import WalletCore

struct DappRequestProcessor {
    
    private static let walletsManager = WalletsManager.shared
    private static let ethereum = Ethereum.shared
    private static let solana = Solana.shared
    private static let near = Near.shared
    
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
        case let .near(body):
            return process(request: request, nearRequest: body, completion: completion)
        case .tezos:
            respond(to: request, error: "Tezos is not supported yet", completion: completion)
            return .none
        case let .unknown(body):
            switch body.method {
            case .justShowApp:
                ExtensionBridge.respond(response: ResponseToExtension(for: request))
                return .justShowApp
            case .switchAccount:
                let preselectedAccounts = body.providerConfigurations.compactMap { (configuration) -> SpecificWalletAccount? in
                    guard let coin = CoinType.correspondingToWeb3Provider(configuration.provider) else { return nil }
                    return walletsManager.getSpecificAccount(coin: coin, address: configuration.address)
                }
                let network = body.providerConfigurations.compactMap { $0.network }.first
                let initiallyConnectedProviders = Set(body.providerConfigurations.map { $0.provider })
                let action = SelectAccountAction(peer: request.peerMeta,
                                                 coinType: nil,
                                                 selectedAccounts: Set(preselectedAccounts),
                                                 initiallyConnectedProviders: initiallyConnectedProviders,
                                                 network: network,
                                                 source: .safariExtension) { chain, specificWalletAccounts in
                    if let chain = chain, let specificWalletAccounts = specificWalletAccounts {
                        var specificProviderBodies = [ResponseToExtension.Body]()
                        for specificWalletAccount in specificWalletAccounts {
                            let account = specificWalletAccount.account
                            switch account.coin {
                            case .ethereum:
                                let responseBody = ResponseToExtension.Ethereum(results: [account.address], chainId: chain.hexStringId, rpcURL: chain.nodeURLString)
                                specificProviderBodies.append(.ethereum(responseBody))
                            case .solana:
                                let responseBody = ResponseToExtension.Solana(publicKey: account.address)
                                specificProviderBodies.append(.solana(responseBody))
                            case .near:
                                let responseBody = ResponseToExtension.Near(account: account.address)
                                specificProviderBodies.append(.near(responseBody))
                            default:
                                fatalError("Can't select that coin")
                            }
                        }
                        
                        let providersToDisconnect = initiallyConnectedProviders.filter { provider in
                            if let coin = CoinType.correspondingToWeb3Provider(provider),
                               specificWalletAccounts.contains(where: { $0.account.coin == coin }) {
                                return false
                            } else {
                                return true
                            }
                        }
                        
                        let body = ResponseToExtension.Multiple(bodies: specificProviderBodies, providersToDisconnect: Array(providersToDisconnect))
                        respond(to: request, body: .multiple(body), completion: completion)
                    } else {
                        respond(to: request, error: Strings.canceled, completion: completion)
                    }
                }
                return .switchAccount(action)
            }
        }
    }
    
    private static func process(request: SafariRequest, nearRequest body: SafariRequest.Near, completion: @escaping () -> Void) -> DappRequestAction {
        let peerMeta = request.peerMeta
        lazy var account = getAccount(coin: .near, address: body.account)
        lazy var privateKey = getPrivateKey(coin: .near, address: body.account)
        
        switch body.method {
        case .signIn:
            let action = SelectAccountAction(peer: peerMeta,
                                             coinType: .near,
                                             selectedAccounts: Set(walletsManager.suggestedAccounts(coin: .near)),
                                             initiallyConnectedProviders: Set(),
                                             network: nil,
                                             source: .safariExtension) { _, specificWalletAccounts in
                if let specificWalletAccount = specificWalletAccounts?.first, specificWalletAccount.account.coin == .near {
                    let responseBody = ResponseToExtension.Near(account: specificWalletAccount.account.address)
                    respond(to: request, body: .near(responseBody), completion: completion)
                } else {
                    respond(to: request, error: Strings.canceled, completion: completion)
                }
            }
            return .selectAccount(action)
        case .signAndSendTransactions:
            guard let account = account, let transactions = body.transactions, !transactions.isEmpty else {
                respond(to: request, error: Strings.somethingWentWrong, completion: completion)
                return .none
            }
            
            let meta: String
            if let jsonObject: Any = transactions.count == 1 ? transactions.first : transactions,
               let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: .prettyPrinted),
               let string = String(data: data, encoding: .utf8) {
                meta = string
            } else {
                meta = Strings.somethingWentWrong
            }
            
            let action = SignMessageAction(provider: request.provider, subject: .approveTransaction, account: account, meta: meta, peerMeta: peerMeta) { approved in
                if approved, let privateKey = privateKey {
                    near.signAndSendTransactions(transactions, account: account, privateKey: privateKey) { result in
                        switch result {
                        case let .success(response):
                            let body = ResponseToExtension.Near(response: response)
                            respond(to: request, body: .near(body), completion: completion)
                        case .failure:
                            respond(to: request, error: Strings.failedToSend, completion: completion)
                        }
                    }
                } else {
                    respond(to: request, error: Strings.failedToSign, completion: completion)
                }
            }
            
            return .approveMessage(action)
        }
    }
    
    private static func process(request: SafariRequest, solanaRequest body: SafariRequest.Solana, completion: @escaping () -> Void) -> DappRequestAction {
        let peerMeta = request.peerMeta
        lazy var account = getAccount(coin: .solana, address: body.publicKey)
        lazy var privateKey = getPrivateKey(coin: .solana, address: body.publicKey)
        
        switch body.method {
        case .connect:
            let action = SelectAccountAction(peer: peerMeta,
                                             coinType: .solana,
                                             selectedAccounts: Set(walletsManager.suggestedAccounts(coin: .solana)),
                                             initiallyConnectedProviders: Set(),
                                             network: nil,
                                             source: .safariExtension) { _, specificWalletAccounts in
                if let specificWalletAccount = specificWalletAccounts?.first, specificWalletAccount.account.coin == .solana {
                    let responseBody = ResponseToExtension.Solana(publicKey: specificWalletAccount.account.address)
                    respond(to: request, body: .solana(responseBody), completion: completion)
                } else {
                    respond(to: request, error: Strings.canceled, completion: completion)
                }
            }
            return .selectAccount(action)
        case .signAllTransactions:
            guard let messages = body.messages, let account = account else {
                respond(to: request, error: Strings.somethingWentWrong, completion: completion)
                return .none
            }
            let displayMessage = Strings.data + ":\n\n" + messages.joined(separator: "\n\n")
            let action = SignMessageAction(provider: request.provider, subject: .approveTransaction, account: account, meta: displayMessage, peerMeta: peerMeta) { approved in
                if approved, let privateKey = privateKey {
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
            guard let message = body.message, let account = account else {
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
                displayMessage = Strings.data + ":\n\n" + message
                subject = .approveTransaction
            }
            let action = SignMessageAction(provider: request.provider, subject: subject, account: account, meta: displayMessage, peerMeta: peerMeta) { approved in
                guard approved, let privateKey = privateKey else {
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
        let peerMeta = request.peerMeta
        lazy var account = getAccount(coin: .ethereum, address: ethereumRequest.address)
        
        switch ethereumRequest.method {
        case .requestAccounts:
            let action = SelectAccountAction(peer: peerMeta,
                                             coinType: .ethereum,
                                             selectedAccounts: Set(walletsManager.suggestedAccounts(coin: .ethereum)),
                                             initiallyConnectedProviders: Set(),
                                             network: nil,
                                             source: .safariExtension) { chain, specificWalletAccounts in
                if let chain = chain, let specificWalletAccount = specificWalletAccounts?.first, specificWalletAccount.account.coin == .ethereum {
                    let responseBody = ResponseToExtension.Ethereum(results: [specificWalletAccount.account.address], chainId: chain.hexStringId, rpcURL: chain.nodeURLString)
                    respond(to: request, body: .ethereum(responseBody), completion: completion)
                } else {
                    respond(to: request, error: Strings.canceled, completion: completion)
                }
            }
            return .selectAccount(action)
        case .signTypedMessage:
            if let raw = ethereumRequest.raw,
               let wallet = walletsManager.getWallet(ethereumAddress: ethereumRequest.address),
               let account = account {
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
               let wallet = walletsManager.getWallet(ethereumAddress: ethereumRequest.address),
               let account = account {
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
               let wallet = walletsManager.getWallet(ethereumAddress: ethereumRequest.address),
               let account = account {
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
               let wallet = walletsManager.getWallet(ethereumAddress: ethereumRequest.address),
               let account = account {
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
    
    private static func getAccount(coin: CoinType, address: String) -> Account? {
        return getWalletAndAccount(coin: coin, address: address)?.1
    }
    
    private static func getPrivateKey(coin: CoinType, address: String) -> WalletCore.PrivateKey? {
        guard let password = Keychain.shared.password else { return nil }
        if let (wallet, account) = getWalletAndAccount(coin: coin, address: address) {
            return try? wallet.privateKey(password: password, account: account)
        } else {
            return nil
        }
    }
    
    private static func getWalletAndAccount(coin: CoinType, address: String) -> (TokenaryWallet, Account)? {
        let searchLowercase = coin == .ethereum
        let needle = searchLowercase ? address.lowercased() : address
        
        for wallet in walletsManager.wallets {
            for account in wallet.accounts where account.coin == coin {
                let match = searchLowercase ? account.address.lowercased() == needle : account.address == needle
                if match {
                    return (wallet, account)
                }
            }
        }
        
        return nil
    }
    
}
