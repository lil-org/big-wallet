// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation
import WalletConnect

class WalletConnect {
 
    static let shared = WalletConnect()
    private init() {}
    
    private var interactors = [WCInteractor]()
    
    func sessionWithLink(_ link: String) -> WCSession? {
        return WCSession.from(string: link)
    }
    
    func connect(session: WCSession, address: String, completion: @escaping ((Bool) -> Void)) {
        let clientMeta = WCPeerMeta(name: "Encrypted Ink", url: "https://encrypted.ink")
        
        let interactor = WCInteractor(session: session, meta: clientMeta, uuid: UUID())
        let id = interactor.clientId
        configure(interactor: interactor, address: address)

        interactor.connect().done { connected in
            completion(connected)
        }.catch { [weak self] _ in
            completion(false)
            self?.removeInteractor(id: id)
        }
        interactors.append(interactor)
    }
    
    func killAllSessions() {
        interactors.forEach {
            $0.killSession().cauterize()
        }
    }
    
    private func removeInteractor(id: String) {
        interactors.removeAll(where: { $0.clientId == id })
    }
    
    private func configure(interactor: WCInteractor, address: String) {
        let accounts = [address]
        let chainId = 1
        let id = interactor.clientId

        interactor.onError = { _ in }

        interactor.onSessionRequest = { [weak interactor] (id, peerParam) in
            let peer = peerParam.peerMeta // TODO: use this data for better UI
            interactor?.approveSession(accounts: accounts, chainId: chainId).cauterize()
        }

        interactor.onDisconnect = { [weak self] _ in
            self?.removeInteractor(id: id)
        }

        interactor.eth.onSign = { [weak self, weak interactor] (id, payload) in
            self?.approveSign(id: id, payload: payload, address: address, interactor: interactor)
        }

        interactor.eth.onTransaction = { [weak self, weak interactor] (id, event, transaction) in
            self?.approveTransaction(id: id, wct: transaction, address: address, interactor: interactor)
        }
    }
    
    private func approveTransaction(id: Int64, wct: WCEthereumTransaction, address: String, interactor: WCInteractor?) {
        guard let to = wct.to else {
            rejectRequest(id: id, interactor: interactor, message: "Something went wrong.")
            return
        }
        
        var transaction = Transaction(from: wct.from, to: to, nonce: wct.nonce, gasPrice: wct.gasPrice, gas: wct.gas, value: wct.value, data: wct.data)
        let approveViewController = Agent.shared.showApprove(title: "Send Transaction", meta: transaction.meta) { [weak self, weak interactor] approved in
            if approved {
                self?.sendTransaction(transaction, address: address, requestId: id, interactor: interactor)
            } else {
                self?.rejectRequest(id: id, interactor: interactor, message: "User canceled")
            }
        }
        
        guard !transaction.hasFee else { return }
        var didDisplayFee = false
        Ethereum.prepareTransaction(transaction) { [weak approveViewController] updated in
            transaction = updated
            if !didDisplayFee, transaction.hasFee {
                didDisplayFee = true
                approveViewController?.setMeta(transaction.meta)
            }
        }
    }

    private func approveSign(id: Int64, payload: WCEthereumSignPayload, address: String, interactor: WCInteractor?) {
        var message: String?
        let title: String
        switch payload {
        case let .sign(data: data, raw: _):
            message = String(data: data, encoding: .utf8)
            title = "Sign Message"
        case let .personalSign(data: data, raw: _):
            message = String(data: data, encoding: .utf8)
            title = "Sign Personal Message"
        case let .signTypeData(id: _, data: _, raw: raw):
            title = "Sign Typed Data"
            if raw.count >= 2 {
                message = raw[1]
            }
        }

        Agent.shared.showApprove(title: title, meta: message ?? "") { [weak self, weak interactor] approved in
            if approved {
                self?.sign(id: id, message: message, payload: payload, address: address, interactor: interactor)
            } else {
                self?.rejectRequest(id: id, interactor: interactor, message: "User canceled")
            }
        }
    }

    private func rejectRequest(id: Int64, interactor: WCInteractor?, message: String) {
        interactor?.rejectRequest(id: id, message: message).cauterize()
    }

    private func sendTransaction(_ transaction: Transaction, address: String, requestId: Int64, interactor: WCInteractor?) {
        guard let account = AccountsService.getAccountForAddress(address) else {
            rejectRequest(id: requestId, interactor: interactor, message: "Failed for some reason")
            return
        }
        guard let hash = try? Ethereum.send(transaction: transaction, account: account) else {
            rejectRequest(id: requestId, interactor: interactor, message: "Failed to send")
            return
        }
        interactor?.approveRequest(id: requestId, result: hash).cauterize()
    }

    private func sign(id: Int64, message: String?, payload: WCEthereumSignPayload, address: String, interactor: WCInteractor?) {
        guard let message = message, let account = AccountsService.getAccountForAddress(address) else {
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
