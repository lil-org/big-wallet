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
    
    func add(session: WCSession, address: String, clientId: String, sessionDetails: WCSessionRequestParam) {
        let item = Item(session: session, address: address, clientId: clientId, sessionDetails: sessionDetails)
        Defaults.storedSessions.append(item)
    }
    
}
