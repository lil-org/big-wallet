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
        
        // TODO: use the same UUID across launches in order to restart sessions correctly
        let interactor = WCInteractor(session: session, meta: clientMeta, uuid: UUID())
        configure(interactor: interactor, address: address)

        interactor.connect().done { connected in
            completion(connected)
        }.catch { _ in
            completion(false)
        }
        interactors.append(interactor)
    }
    
    func configure(interactor: WCInteractor, address: String) {
        let accounts = [address]
        let chainId = 1

        interactor.onError = { _ in }

        interactor.onSessionRequest = { [weak interactor] (id, peerParam) in
            let peer = peerParam.peerMeta // TODO: use this data for better UI
            interactor?.approveSession(accounts: accounts, chainId: chainId).cauterize()
        }

        interactor.onDisconnect = { _ in }

        interactor.eth.onSign = { [weak self, weak interactor] (id, payload) in
            self?.approveSign(id: id, payload: payload, address: address, interactor: interactor)
        }

        interactor.eth.onTransaction = { [weak self, weak interactor] (id, event, transaction) in
            self?.approveTransaction(id: id, wct: transaction, address: address, interactor: interactor)
        }
    }
    
    private func approveTransaction(id: Int64, wct: WCEthereumTransaction, address: String, interactor: WCInteractor?) {
        let value = Double(UInt64(wct.value?.dropFirst(2) ?? "0", radix: 16) ?? 0) / 1e18
        Agent.shared.showApprove(title: "Send Transaction", meta: "value: \(value) ETH\n\ndata: \(wct.data)") { [weak self] approved in
            if approved {
                self?.sendTransaction(id: id, wct: wct, address: address, interactor: interactor)
            } else {
                self?.rejectRequest(id: id, interactor: interactor, message: "User canceled")
            }
        }
    }

    func approveSign(id: Int64, payload: WCEthereumSignPayload, address: String, interactor: WCInteractor?) {
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

        Agent.shared.showApprove(title: title, meta: message ?? "") { [weak self] approved in
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
        guard let account = AccountsService.getAccountForAddress(address) else {
            rejectRequest(id: id, interactor: interactor, message: "Failed for some reason")
            return
        }
        
        
        // это данные, которые использует токенари macos
        let dict: [String: Any] = ["from": wct.from, "to": wct.to, "nonce": wct.nonce, "gasPrice": wct.gasPrice, "gas": wct.gas, "gasLimit": wct.gasLimit, "value": wct.value, "data": wct.data]
        Transaction.make(fromDictionary: dict, accountAddress: address, previousNonce: nil)
        
        
        
        // Это данные, которые есть
        public let from: String
        public let to: String?
        public let nonce: String?
        public let gasPrice: String?
        public let gas: String?
        public let gasLimit: String? // legacy gas limit
        public let value: String?
        public let data: String
        
        
        
        
        
        // а вот так в токенари на мобиле
        guard let fromAddress = Address(string: address),
            let toAddress = Address(string: transaction.to),
            let value = BigNumber(hexString: transaction.value),
            let nonce = UInt(String(transaction.nonce.dropFirst(2)), radix: 16),
            let gasLimit = BigNumber(hexString: transaction.gasLimit),
            let gasPrice = BigNumber(hexString: transaction.gasPrice) else { return }
        
        
        
        
        
        
        // а вот такие данные берет гнозис
        to: \(String(describing: to!.hex(eip55: true))),
                value: \(String(describing: value!.hex())),
                gasPrice: \(String(describing: gasPrice!.hex())),
                gas: \(String(describing: gas!.hex())),
                data: \(data.hex()),
                nonce: \(String(describing: nonce!.hex()))
        
        
        
        
        let transactionToSend = Transaction(from: fromAddress)
        transactionToSend.toAddress = toAddress
        transactionToSend.value = value
        transactionToSend.data = Data(hex: transaction.data)
        transactionToSend.chainId = .ChainIdHomestead
        transactionToSend.nonce = nonce
        transactionToSend.gasLimit = gasLimit
        transactionToSend.gasPrice = gasPrice
        
        
        
        
        
        
        
        
        
        
        
        
        
        let transaction = Transaction(transactionsCount: wct.nonce,
                                      gasPrice: wct.gasPrice,
                                      gasEstimate: wct.gasLimit,
                                      recipientAddress: wct.to ?? "",
                                      weiAmount: wct.value ?? "",
                                      contractCall: wct.data)
        guard let hash = try? Ethereum.send(transaction: transaction, account: account) else {
            rejectRequest(id: id, interactor: interactor, message: "Failed to send")
            return
        }
        interactor?.approveRequest(id: id, result: hash).cauterize()
    }

    func sign(id: Int64, message: String?, payload: WCEthereumSignPayload, address: String, interactor: WCInteractor?) {
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
