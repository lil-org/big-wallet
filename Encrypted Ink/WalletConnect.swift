// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation
import WalletConnect
import Cocoa // TODO: for testing purposes

class WalletConnect {
 
    static let shared = WalletConnect()
    private init() {}
    
    private var interactors = [WCInteractor]()
    
    func connect(link: String, address: String, completion: @escaping ((Bool) -> Void)) {
        let clientMeta = WCPeerMeta(name: "Encrypted Ink", url: "https://encrypted.ink")
        guard let session = WCSession.from(string: link) else {
            return
        }
        
        let interactor = WCInteractor(session: session, meta: clientMeta, uuid: UUID())
        configure(interactor: interactor, address: address)

        interactor.connect().done { connected in
            completion(connected)
        }.catch { error in
            print(error)
        }
        interactors.append(interactor)
    }
    
    func configure(interactor: WCInteractor, address: String) {
        let accounts = [address]
        let chainId = 1

        interactor.onError = { error in
            print(error)
        }

        interactor.onSessionRequest = { [weak interactor] (id, peerParam) in
            let peer = peerParam.peerMeta
            interactor?.approveSession(accounts: accounts, chainId: chainId).cauterize()
        }

        interactor.onDisconnect = { (error) in
            print(error)
        }

        interactor.eth.onSign = { [weak self, weak interactor] (id, payload) in
            print(id, payload)
            self?.approveSign(id: id, payload: payload, address: address, interactor: interactor)
        }

        interactor.eth.onTransaction = { [weak self, weak interactor] (id, event, transaction) in
            print(id, event, transaction)
            self?.approveTransaction(id: id, wct: transaction, address: address, interactor: interactor)
        }
    }
    
    private func approveTransaction(id: Int64, wct: WCEthereumTransaction, address: String, interactor: WCInteractor?) {
        Agent.shared.showApprove(title: "Send Transaction", meta: "xxx ETH") { [weak self] approved in
            if approved {
                self?.sendTransaction(id: id, wct: wct, address: address, interactor: interactor)
            } else {
                self?.rejectRequest(id: id, interactor: interactor, message: "User canceled")
            }
        }
    }

    func approveSign(id: Int64, payload: WCEthereumSignPayload, address: String, interactor: WCInteractor?) {
        var message: String?
        switch payload {
        case let .sign(data: data, raw: _):
            message = String(data: data, encoding: .utf8)
        case let .personalSign(data: data, raw: _):
            message = String(data: data, encoding: .utf8)
        case let .signTypeData(id: _, data: _, raw: raw):
            if raw.count >= 2 {
                message = raw[1]
            }
        }

        // TODO: vary title depending on sign type
        Agent.shared.showApprove(title: "Sign message", meta: message ?? "") { [weak self] approved in
            if approved {
                self?.sign(id: id, message: message, payload: payload, address: address, interactor: interactor)
            } else {
                self?.rejectRequest(id: id, interactor: interactor, message: "User canceled")
            }
        }
    }

    func rejectRequest(id: Int64, interactor: WCInteractor?, message: String) {
        interactor?.rejectRequest(id: id, message: message).cauterize()
    }

    func sendTransaction(id: Int64, wct: WCEthereumTransaction, address: String, interactor: WCInteractor?) {
        let dict: [String: Any] = ["from": wct.from, "to": wct.to, "nonce": wct.nonce, "gasPrice": wct.gasPrice, "gas": wct.gas, "gasLimit": wct.gasLimit, "value": wct.value, "data": wct.data]
        
        // TODO: these are possible results
//        rejectRequest(id: id, interactor: interactor, message: "Failed to send transaction") // TODO: show error in this case
//        interactor?.approveRequest(id: id, result: hash.hexString).cauterize()
    }

    func sign(id: Int64, message: String?, payload: WCEthereumSignPayload, address: String, interactor: WCInteractor?) {
        guard
            let message = message,
            let account = AccountsService.getAccounts().filter({ $0.address == address.lowercased() }).first
        else {
            rejectRequest(id: id, interactor: interactor, message: "Failed for some reason")
            return
        }
        var signed: String?
        switch payload {
        case .personalSign:
            signed = try? Ethereum.signPersonal(message: message, account: account)
        case .signTypeData:
            signed = try? Ethereum.sign(typedData: message, account: account)
        case .sign:
            signed = try? Ethereum.sign(message: message, account: account)
        }
        guard let result = signed else {
            rejectRequest(id: id, interactor: interactor, message: "Failed for some reason")
            return
        }
        
        interactor?.approveRequest(id: id, result: result).cauterize()
    }
    
}
