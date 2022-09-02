// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

struct WalletsMetadata: Codable {
    
    var externalAccounts: [String: [ExternalAccount]]
    
}
