// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

extension SafariRequest {
    
    struct Solana: SafariRequestBody {
        
        init?(name: String, json: [String: Any]) {
            
        }
        
        var responseUpdatesStoredConfiguration: Bool {
            return false
        }
        
    }
    
}
