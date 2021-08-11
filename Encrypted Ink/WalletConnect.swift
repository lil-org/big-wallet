// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation
import WalletConnect

class WalletConnect {
 
    private let sessionStorage = SessionStorage.shared
    private let networkMonitor = NetworkMonitor.shared
    private let ethereum = Ethereum.shared
    private let walletsManager = WalletsManager.shared
    
    static let shared = WalletConnect()
    
    private init() {
        NotificationCenter.default.addObserver(self, selector: #selector(connectionAppeared), name: .connectionAppeared, object: nil)
    }
    
    private var interactors = [WCInteractor]()
    private var interactorsPendingReconnection = [String: WCInteractor]()
    private var peers = [String: WCPeerMeta]()
    
    func sessionWithLink(_ link: String) -> WCSession? {
        return WCSession.from(string: link)
    }
    
    func connect(session: WCSession, chainId: Int, walletId: String, uuid: UUID = UUID(), completion: @escaping ((Bool) -> Void)) {
        let clientMeta = WCPeerMeta(name: "Encrypted Ink", url: "https://encrypted.ink", description: "Ethereum agent for macOS", icons: ["https://encrypted.ink/icon.png"])
        let interactor = WCInteractor(session: session, meta: clientMeta, uuid: uuid)
        configure(interactor: interactor, chainId: chainId, walletId: walletId)

        interactor.connect().done { connected in
            completion(connected)
        }.catch { [weak self, weak interactor] _ in
            completion(false)
            if let interactor = interactor {
                self?.didDisconnect(interactor: interactor)
            }
        }
        interactors.append(interactor)
    }
    
    func restartSessions() {
        let items = sessionStorage.loadAll()
        
        for item in items {
            guard let uuid = UUID(uuidString: item.clientId) else { continue }
            connect(session: item.session, chainId: item.chainId ?? 1, walletId: item.walletId, uuid: uuid) { _ in }
            peers[item.clientId] = item.sessionDetails.peerMeta
        }
    }
    
    @objc private func connectionAppeared() {
        if !interactorsPendingReconnection.isEmpty {
            reconnectPendingInteractors()
        }
    }
    
    private func reconnectPendingInteractors() {
        let pending = interactorsPendingReconnection.values
        interactorsPendingReconnection = [:]
        pending.forEach {
            $0.resume()
        }
    }
    
    private func didDisconnect(interactor: WCInteractor) {
        if sessionStorage.shouldReconnect(interactor: interactor) {
            reconnectWhenPossible(interactor: interactor)
        } else {
            removeInteractor(id: interactor.clientId)
        }
    }
    
    private func removeInteractor(id: String) {
        interactors.removeAll(where: { $0.clientId == id })
        peers.removeValue(forKey: id)
        sessionStorage.remove(clientId: id)
    }
    
    private func getPeerOfInteractor(_ interactor: WCInteractor?) -> WCPeerMeta? {
        guard let id = interactor?.clientId else { return nil }
        return peers[id]
    }
    
    private func configure(interactor: WCInteractor, chainId: Int, walletId: String) {
        guard let address = walletsManager.getWallet(id: walletId)?.ethereumAddress else { return }
        let accounts = [address]
        
        interactor.onError = { _ in }

        interactor.onSessionRequest = { [weak self, weak interactor] (id, peerParam) in
            guard let interactor = interactor else { return }
            self?.peers[interactor.clientId] = peerParam.peerMeta
            self?.sessionStorage.add(interactor: interactor, chainId: chainId, walletId: walletId, sessionDetails: peerParam)
            interactor.approveSession(accounts: accounts, chainId: chainId).cauterize()
        }

        interactor.onDisconnect = { [weak interactor, weak self] _ in
            if let interactor = interactor {
                self?.didDisconnect(interactor: interactor)
            }
        }

        interactor.eth.onSign = { [weak self, weak interactor] (id, payload) in
            self?.approveSign(id: id, payload: payload, walletId: walletId, interactor: interactor)
            self?.sessionStorage.didInteractWith(clientId: interactor?.clientId)
        }

        interactor.eth.onTransaction = { [weak self, weak interactor] (id, event, transaction) in
            self?.approveTransaction(id: id, wct: transaction, walletId: walletId, chainId: chainId, interactor: interactor)
            self?.sessionStorage.didInteractWith(clientId: interactor?.clientId)
        }
    }
    
    private func reconnectWhenPossible(interactor: WCInteractor) {
        DispatchQueue.main.async { [weak self] in
            self?.interactorsPendingReconnection[interactor.clientId] = interactor
            if self?.interactorsPendingReconnection.count == 1 && self?.networkMonitor.hasConnection == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(7)) {
                    self?.reconnectPendingInteractors()
                }
            }
        }
    }
    
    private func approveTransaction(id: Int64, wct: WCEthereumTransaction, walletId: String, chainId: Int, interactor: WCInteractor?) {
        guard let to = wct.to, let chain = EthereumChain(rawValue: chainId) else {
            rejectRequest(id: id, interactor: interactor, message: "Something went wrong.")
            return
        }
        
        let peer = getPeerOfInteractor(interactor)
        let transaction = Transaction(from: wct.from, to: to, nonce: wct.nonce, gasPrice: wct.gasPrice, gas: wct.gas, value: wct.value, data: wct.data)
        Agent.shared.showApprove(transaction: transaction, chain: chain, peerMeta: peer) { [weak self, weak interactor] transaction in
            if let transaction = transaction {
                self?.sendTransaction(transaction, walletId: walletId, chainId: chainId, requestId: id, interactor: interactor)
            } else {
                self?.rejectRequest(id: id, interactor: interactor, message: "Cancelled")
            }
        }
    }

    private func approveSign(id: Int64, payload: WCEthereumSignPayload, walletId: String, interactor: WCInteractor?) {
        var message: String?

        let signingItem: SigningItem
        switch payload {
        case let .sign(data: data, raw: _):
            message = String(data: data, encoding: .utf8)
            signingItem = .message
        case let .personalSign(data: data, raw: _):
            message = String(data: data, encoding: .utf8)
            signingItem = .personalMessage
        case let .signTypeData(id: _, data: _, raw: raw):
            signingItem = .typedData
            if raw.count >= 2 {
                message = raw[1]
            }
        }

        let peer = getPeerOfInteractor(interactor)
        Agent.shared.showApprove(signingItem: signingItem, meta: message ?? "", peerMeta: peer) { [weak self, weak interactor] approved in
            if approved {
                self?.sign(id: id, message: message, payload: payload, walletId: walletId, interactor: interactor)
            } else {
                self?.rejectRequest(id: id, interactor: interactor, message: "Cancelled")
            }
        }
    }

    private func rejectRequest(id: Int64, interactor: WCInteractor?, message: String) {
        interactor?.rejectRequest(id: id, message: message).cauterize()
    }

    private func sendTransaction(_ transaction: Transaction, walletId: String, chainId: Int, requestId: Int64, interactor: WCInteractor?) {
        guard let wallet = walletsManager.getWallet(id: walletId), let chain = EthereumChain(rawValue: chainId) else {
            rejectRequest(id: requestId, interactor: interactor, message: "Something went wrong.")
            return
        }
        guard let hash = try? ethereum.send(transaction: transaction, wallet: wallet, chain: chain) else {
            rejectRequest(id: requestId, interactor: interactor, message: "Failed to send")
            return
        }
        interactor?.approveRequest(id: requestId, result: hash).cauterize()
    }

    private func sign(id: Int64, message: String?, payload: WCEthereumSignPayload, walletId: String, interactor: WCInteractor?) {
        guard let message = message, let wallet = walletsManager.getWallet(id: walletId) else {
            rejectRequest(id: id, interactor: interactor, message: "Something went wrong.")
            return
        }
        var signed: String?
        switch payload {
        case .personalSign:
            signed = try? ethereum.signPersonal(message: message, wallet: wallet)
        case .signTypeData:
            signed = try? ethereum.sign(typedData: message, wallet: wallet)
        case .sign:
            signed = try? ethereum.sign(message: message, wallet: wallet)
        }
        guard let result = signed else {
            rejectRequest(id: id, interactor: interactor, message: "Something went wrong.")
            return
        }
        interactor?.approveRequest(id: id, result: result).cauterize()
    }
    
}
