// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

struct WalletsMetadata: Codable {
    
    var forWallet: [String: WalletMetadata]
    
    init() {
        self.forWallet = [:]
    }
    
}

struct WalletMetadata: Codable {
    var externalAccounts: [ExternalAccount]
    // TODO: how are we gona keep ens / custom account names here?
}
