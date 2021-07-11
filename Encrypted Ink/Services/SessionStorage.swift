// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation
import WalletConnect

class SessionStorage {
    
    struct Item: Codable {
        let session: WCSession
        let address: String
        let clientId: String
        let sessionDetails: WCSessionRequestParam
    }
    
    static let shared = SessionStorage()
    
    private init() {}
    
    func loadAll() -> [Item] {
        let items = Array(Defaults.storedSessions.values)
        let wcItems = WCSessionStore.allSessions
        for item in items where wcItems[item.session.topic] == nil {
            WCSessionStore.store(item.session, peerId: item.sessionDetails.peerId, peerMeta: item.sessionDetails.peerMeta)
        }
        return items
    }
    
    func removeAll() {
        Defaults.storedSessions = [:]
    }
    
    func remove(clientId: String) {
        if let item = Defaults.storedSessions.removeValue(forKey: clientId) {
            WCSessionStore.clear(item.session.topic)
        }
    }
    
    func add(interactor: WCInteractor, address: String, sessionDetails: WCSessionRequestParam) {
        let item = Item(session: interactor.session, address: address, clientId: interactor.clientId, sessionDetails: sessionDetails)
        WCSessionStore.store(interactor.session, peerId: sessionDetails.peerId, peerMeta: sessionDetails.peerMeta)
        Defaults.storedSessions[interactor.clientId] = item
        didInteractWith(clientId: interactor.clientId)
    }
    
    func didInteractWith(clientId: String?) {
        guard let clientId = clientId else { return }
        Defaults.latestInteractionDates[clientId] = Date()
    }
    
    func shouldReconnect(interactor: WCInteractor) -> Bool {
        return WCSessionStore.load(interactor.session.topic) != nil
    }
    
}
