// Copyright © 2021 Tokenary. All rights reserved.

import Foundation
import WalletConnect

class SessionStorage {
    
    struct Item: Codable {
        let session: WCSession
        let chainId: Int?
        let walletId: String
        let clientId: String
        let sessionDetails: WCSessionRequestParam
    }
    
    static let shared = SessionStorage()
    
    private init() {}
    
    func loadAll() -> [Item] {
        var items = Array(Defaults.storedSessions.values)
        let wcItems = WCSessionStore.allSessions
        let latestInteractionDates = Defaults.latestInteractionDates
        let now = Date()
        let oldnessThreshold: Double = 60 * 60 * 24 * 60 // 60 days
        
        items = items.filter { item -> Bool in
            guard let date = latestInteractionDates[item.clientId], now.timeIntervalSince(date) < oldnessThreshold else {
                remove(clientId: item.clientId)
                return false
            }
            
            if wcItems[item.session.topic] == nil {
                WCSessionStore.store(item.session, peerId: item.sessionDetails.peerId, peerMeta: item.sessionDetails.peerMeta)
            }
            
            return true
        }
        
        return items
    }
    
    func removeAll() {
        Defaults.storedSessions = [:]
        Defaults.latestInteractionDates = [:]
    }
    
    func remove(clientId: String) {
        Defaults.latestInteractionDates.removeValue(forKey: clientId)
        if let item = Defaults.storedSessions.removeValue(forKey: clientId) {
            WCSessionStore.clear(item.session.topic)
        }
    }
    
    func add(interactor: WCInteractor, chainId: Int, walletId: String, sessionDetails: WCSessionRequestParam) {
        let item = Item(session: interactor.session, chainId: chainId, walletId: walletId, clientId: interactor.clientId, sessionDetails: sessionDetails)
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
