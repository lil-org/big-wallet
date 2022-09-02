// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

struct WalletsMetadata: Codable {
    
    var forWallet: [String: WalletMetadata]
    
    init() {
        self.forWallet = [:]
    }
    
}

struct WalletMetadata: Codable {
    // TODO: keep ens / custom accounts names here as well
    
    var externalAccounts: [ExternalAccount]
    
    init() {
        self.externalAccounts = []
    }
    
}
