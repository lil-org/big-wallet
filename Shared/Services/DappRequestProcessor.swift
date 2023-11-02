// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import WalletCore

struct DappRequestProcessor {
    
    private static let walletsManager = WalletsManager.shared
    private static let ethereum = Ethereum.shared
    
    static func processSafariRequest(_ request: SafariRequest, completion: @escaping () -> Void) -> DappRequestAction {
        guard ExtensionBridge.hasRequest(id: request.id) else {
            respond(to: request, error: Strings.somethingWentWrong, completion: completion)
            return .none
        }
        
        switch request.body {
        case let .ethereum(body):
            return process(request: request, ethereumRequest: body, completion: completion)
        case let .unknown(body):
            switch body.method {
            case .justShowApp:
                ExtensionBridge.respond(response: ResponseToExtension(for: request))
                return .justShowApp
            case .switchAccount:
                let preselectedAccounts = body.providerConfigurations.compactMap { (configuration) -> SpecificWalletAccount? in
                    guard let coin = CoinType.correspondingToInpageProvider(configuration.provider) else { return nil }
                    return walletsManager.getSpecificAccount(coin: coin, address: configuration.address)
                }
                let chainId = body.providerConfigurations.compactMap { $0.chainId }.first
                let network = Networks.withChainIdHex(chainId)
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
                                let responseBody = ResponseToExtension.Ethereum(results: [account.address],
                                                                                chainId: chain.chainIdHexString,
                                                                                rpcURL: chain.nodeURLString)
                                specificProviderBodies.append(.ethereum(responseBody))
                            default:
                                fatalError("Can't select that coin")
                            }
                        }
                        
                        let providersToDisconnect = initiallyConnectedProviders.filter { provider in
                            if let coin = CoinType.correspondingToInpageProvider(provider),
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
    
    private static func process(request: SafariRequest, ethereumRequest: SafariRequest.Ethereum, completion: @escaping () -> Void) -> DappRequestAction {
        let peerMeta = request.peerMeta
        lazy var account = walletsManager.getAccount(coin: .ethereum, address: ethereumRequest.address)
        lazy var privateKey = walletsManager.getPrivateKey(coin: .ethereum, address: ethereumRequest.address)
        
        switch ethereumRequest.method {
        case .requestAccounts:
            let action = SelectAccountAction(peer: peerMeta,
                                             coinType: .ethereum,
                                             selectedAccounts: Set(walletsManager.suggestedAccounts(coin: .ethereum)),
                                             initiallyConnectedProviders: Set(),
                                             network: nil,
                                             source: .safariExtension) { chain, specificWalletAccounts in
                if let chain = chain, let specificWalletAccount = specificWalletAccounts?.first, specificWalletAccount.account.coin == .ethereum {
                    let responseBody = ResponseToExtension.Ethereum(results: [specificWalletAccount.account.address], chainId: chain.chainIdHexString, rpcURL: chain.nodeURLString)
                    respond(to: request, body: .ethereum(responseBody), completion: completion)
                } else {
                    respond(to: request, error: Strings.canceled, completion: completion)
                }
            }
            return .selectAccount(action)
        case .signTypedMessage:
            if let raw = ethereumRequest.raw,
               let account = account,
               let privateKey = privateKey {
                let action = SignMessageAction(provider: request.provider, subject: .signTypedData, account: account, meta: raw, peerMeta: peerMeta) { approved in
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
               let account = account,
               let privateKey = privateKey {
                let action = SignMessageAction(provider: request.provider, subject: .signMessage, account: account, meta: data.hexString, peerMeta: peerMeta) { approved in
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
               let account = account,
               let privateKey = privateKey {
                let text = String(data: data, encoding: .utf8) ?? data.hexString
                let action = SignMessageAction(provider: request.provider, subject: .signPersonalMessage, account: account, meta: text, peerMeta: peerMeta) { approved in
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
               let account = account,
               let privateKey = privateKey {
                let action = SendTransactionAction(provider: request.provider,
                                                   transaction: transaction,
                                                   chain: chain,
                                                   account: account,
                                                   peerMeta: peerMeta) { transaction in
                    if let transaction = transaction {
                        sendTransaction(privateKey: privateKey, transaction: transaction, network: chain, request: request, completion: completion)
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
    
    private static func signTypedData(privateKey: PrivateKey, raw: String, request: SafariRequest, completion: () -> Void) {
        if let signed = try? ethereum.sign(typedData: raw, privateKey: privateKey) {
            respond(to: request, body: .ethereum(.init(result: signed)), completion: completion)
        } else {
            respond(to: request, error: Strings.failedToSign, completion: completion)
        }
    }
    
    private static func signMessage(privateKey: PrivateKey, data: Data, request: SafariRequest, completion: () -> Void) {
        if let signed = try? ethereum.sign(data: data, privateKey: privateKey) {
            respond(to: request, body: .ethereum(.init(result: signed)), completion: completion)
        } else {
            respond(to: request, error: Strings.failedToSign, completion: completion)
        }
    }
    
    private static func signPersonalMessage(privateKey: PrivateKey, data: Data, request: SafariRequest, completion: () -> Void) {
        if let signed = try? ethereum.signPersonalMessage(data: data, privateKey: privateKey) {
            respond(to: request, body: .ethereum(.init(result: signed)), completion: completion)
        } else {
            respond(to: request, error: Strings.failedToSign, completion: completion)
        }
    }
     
    private static func sendTransaction(privateKey: PrivateKey, transaction: Transaction, network: EthereumNetwork, request: SafariRequest, completion: @escaping () -> Void) {
        ethereum.send(transaction: transaction, privateKey: privateKey, network: network) { hash in
            if let hash = hash {
                DappRequestProcessor.respond(to: request, body: .ethereum(.init(result: hash)), completion: completion)
            } else {
                respond(to: request, error: Strings.failedToSend, completion: completion)
            }
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
