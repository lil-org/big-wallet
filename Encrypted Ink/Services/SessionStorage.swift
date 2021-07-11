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
        return Defaults.storedSessions
    }
    
    func removeAll() {
        Defaults.storedSessions = []
    }
    
    func add(interactor: WCInteractor, address: String, sessionDetails: WCSessionRequestParam) {
        // TODO: store session if it is not already stored
        let item = Item(session: interactor.session, address: address, clientId: interactor.clientId, sessionDetails: sessionDetails)
        WCSessionStore.store(interactor.session, peerId: sessionDetails.peerId, peerMeta: sessionDetails.peerMeta)
        Defaults.storedSessions.append(item)
    }
    
}
