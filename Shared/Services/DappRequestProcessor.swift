// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

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
                let action = SelectAccountAction(provider: .unknown) { chain, wallet in
                    // TODO: should work with any chain
                    if let chain = chain, let address = wallet?.ethereumAddress {
                        let responseBody = ResponseToExtension.Ethereum(results: [address], chainId: chain.hexStringId, rpcURL: chain.nodeURLString)
                        respond(to: request, body: .ethereum(responseBody), completion: completion)
                        // TODO: response body type should depend on chain of selected account
                    } else {
                        respond(to: request, error: Strings.canceled, completion: completion)
                    }
                }
                return .selectAccount(action)
            }
        case .solana:
            respond(to: request, error: "Solana is not supported yet", completion: completion)
        case .tezos:
            respond(to: request, error: "Tezos is not supported yet", completion: completion)
        }
        return .none
    }
    
    private static func process(request: SafariRequest, ethereumRequest: SafariRequest.Ethereum, completion: @escaping () -> Void) -> DappRequestAction {
        let peerMeta = PeerMeta(title: request.host, iconURLString: request.favicon)
        
        switch ethereumRequest.method {
        case .switchAccount, .requestAccounts:
            let action = SelectAccountAction(provider: .ethereum) { chain, wallet in
                if let chain = chain, let address = wallet?.ethereumAddress {
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
               let address = wallet.ethereumAddress {
                let action = SignMessageAction(provider: request.provider, subject: .signTypedData, address: address, meta: raw, peerMeta: peerMeta) { approved in
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
               let address = wallet.ethereumAddress {
                let action = SignMessageAction(provider: request.provider, subject: .signMessage, address: address, meta: data.hexString, peerMeta: peerMeta) { approved in
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
               let address = wallet.ethereumAddress {
                let text = String(data: data, encoding: .utf8) ?? data.hexString
                let action = SignMessageAction(provider: request.provider, subject: .signPersonalMessage, address: address, meta: text, peerMeta: peerMeta) { approved in
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
               let address = wallet.ethereumAddress {
                let action = SendTransactionAction(provider: request.provider,
                                                   transaction: transaction,
                                                   chain: chain,
                                                   address: address,
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
