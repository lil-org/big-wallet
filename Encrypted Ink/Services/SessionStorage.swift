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
        let items = Defaults.storedSessions
        let wcItems = WCSessionStore.allSessions
        for item in items where wcItems[item.session.topic] == nil {
            WCSessionStore.store(item.session, peerId: item.sessionDetails.peerId, peerMeta: item.sessionDetails.peerMeta)
        }
        return items
    }
    
    func removeAll() {
        Defaults.storedSessions = []
    }
    
    func add(interactor: WCInteractor, address: String, sessionDetails: WCSessionRequestParam) {
        // TODO: store session if it is not already stored
        // but maybe should update already stored values
        let item = Item(session: interactor.session, address: address, clientId: interactor.clientId, sessionDetails: sessionDetails)
        WCSessionStore.store(interactor.session, peerId: sessionDetails.peerId, peerMeta: sessionDetails.peerMeta)
        Defaults.storedSessions.append(item)
    }
    
    func shouldReconnect(interactor: WCInteractor) -> Bool {
        return WCSessionStore.load(interactor.session.topic) != nil
    }
    
}
