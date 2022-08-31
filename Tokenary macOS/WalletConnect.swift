// Copyright © 2021 Tokenary. All rights reserved.

import Foundation
import WalletConnect

class WalletConnect {
 
    private lazy var agent = Agent.shared
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
        let clientMeta = WCPeerMeta(name: Strings.tokenary, url: "https://tokenary.io", description: Strings.walletConnectClientDescription, icons: ["https://tokenary.io/icon.png"])
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
        var chainId = chainId
        
        interactor.onError = { _ in }

        interactor.onSessionRequest = { [weak self, weak interactor] (_, peerParam) in
            guard let interactor = interactor else { return }
            if let requestedChainId = peerParam.chainId {
                chainId = requestedChainId
            }
            
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

        interactor.eth.onTransaction = { [weak self, weak interactor] (id, _, transaction) in
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
            rejectRequest(id: id, interactor: interactor, message: Strings.somethingWentWrong)
            return
        }
        
        let peer = PeerMeta(wcPeerMeta: getPeerOfInteractor(interactor))
        let transaction = Transaction(from: wct.from, to: to, nonce: wct.nonce, gasPrice: wct.gasPrice, gas: wct.gas, value: wct.value, data: wct.data)
        let windowController = Window.showNew(closeOthers: false)
        let windowNumber = windowController.window?.windowNumber
        agent.showApprove(windowController: windowController, browser: .unknown, transaction: transaction, chain: chain, peerMeta: peer) { [weak self, weak interactor] transaction in
            if let transaction = transaction {
                self?.sendTransaction(transaction, walletId: walletId, chainId: chainId, requestId: id, interactor: interactor)
                Window.closeWindowAndActivateNext(idToClose: windowNumber, specificBrowser: nil)
            } else {
                Window.closeWindowAndActivateNext(idToClose: windowNumber, specificBrowser: nil)
                self?.rejectRequest(id: id, interactor: interactor, message: Strings.canceled)
            }
        }
    }

    private func approveSign(id: Int64, payload: WCEthereumSignPayload, walletId: String, interactor: WCInteractor?) {
        var message: String?
        let approvalSubject: ApprovalSubject
        switch payload {
        case let .sign(data: data, raw: _):
            message = String(data: data, encoding: .utf8) ?? data.hexString
            approvalSubject = .signMessage
        case let .personalSign(data: data, raw: _):
            message = String(data: data, encoding: .utf8) ?? data.hexString
            approvalSubject = .signPersonalMessage
        case let .signTypeData(id: _, data: _, raw: raw):
            approvalSubject = .signTypedData
            if raw.count >= 2 {
                message = raw[1]
            }
        }

        let peer = PeerMeta(wcPeerMeta: getPeerOfInteractor(interactor))
        let windowController = Window.showNew(closeOthers: false)
        let windowNumber = windowController.window?.windowNumber
        agent.showApprove(windowController: windowController, browser: .unknown, subject: approvalSubject, meta: message ?? "", peerMeta: peer) { [weak self, weak interactor] approved in
            if approved {
                self?.sign(id: id, payload: payload, walletId: walletId, interactor: interactor)
                Window.closeWindowAndActivateNext(idToClose: windowNumber, specificBrowser: nil)
            } else {
                Window.closeWindowAndActivateNext(idToClose: windowNumber, specificBrowser: nil)
                self?.rejectRequest(id: id, interactor: interactor, message: Strings.canceled)
            }
        }
    }

    private func rejectRequest(id: Int64, interactor: WCInteractor?, message: String) {
        interactor?.rejectRequest(id: id, message: message).cauterize()
    }

    private func sendTransaction(_ transaction: Transaction, walletId: String, chainId: Int, requestId: Int64, interactor: WCInteractor?) {
        guard let wallet = walletsManager.getWallet(id: walletId), let chain = EthereumChain(rawValue: chainId) else {
            rejectRequest(id: requestId, interactor: interactor, message: Strings.somethingWentWrong)
            return
        }
        guard let hash = try? ethereum.send(transaction: transaction, wallet: wallet, chain: chain) else {
            rejectRequest(id: requestId, interactor: interactor, message: Strings.failedToSend)
            return
        }
        interactor?.approveRequest(id: requestId, result: hash).cauterize()
        ReviewRequster.requestReviewIfNeeded()
    }

    private func sign(id: Int64, payload: WCEthereumSignPayload, walletId: String, interactor: WCInteractor?) {
        guard let wallet = walletsManager.getWallet(id: walletId) else {
            rejectRequest(id: id, interactor: interactor, message: Strings.somethingWentWrong)
            return
        }
        var signed: String?
        switch payload {
        case let .personalSign(data: data, raw: _):
            signed = try? ethereum.signPersonalMessage(data: data, wallet: wallet)
        case let .signTypeData(id: _, data: _, raw: raw):
            let typedData = raw.count >= 2 ? raw[1] : ""
            signed = try? ethereum.sign(typedData: typedData, wallet: wallet)
        case let .sign(data: data, raw: _):
            signed = try? ethereum.sign(data: data, wallet: wallet)
        }
        guard let result = signed else {
            rejectRequest(id: id, interactor: interactor, message: Strings.somethingWentWrong)
            return
        }
        interactor?.approveRequest(id: id, result: result).cauterize()
        ReviewRequster.requestReviewIfNeeded()
    }
    
}
