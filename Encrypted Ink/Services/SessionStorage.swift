// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation
import WalletConnect

class SessionStorage {
    
    struct Item: Codable {
        let session: WCSession
        let address: String
        let uuid: UUID
    }
    
    static let shared = SessionStorage()
    
    private init() {}
    
    func loadAll() -> [Item] {
        return []
    }
    
    func add(session: WCSession, address: String, uuid: UUID) {
        // TODO: implement
    }
    
}
