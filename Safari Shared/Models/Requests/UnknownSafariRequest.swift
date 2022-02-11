// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

extension SafariRequest {
    
    struct Unknown: SafariRequestBody {
        
        init?(name: String, json: [String: Any]) {
            
        }
        
        var responseUpdatesStoredConfiguration: Bool {
            return true
        }
        
    }
    
}
