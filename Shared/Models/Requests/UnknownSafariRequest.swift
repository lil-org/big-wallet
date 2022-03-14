// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

extension SafariRequest {
    
    struct Unknown: SafariRequestBody {
        
        enum Method: String, Decodable, CaseIterable {
            case justShowApp
            case switchAccount
        }
        
        let method: Method
        
        init?(name: String, json: [String: Any]) {
            guard let method = Method(rawValue: name) else { return nil }
            self.method = method
        }
        
        var responseUpdatesStoredConfiguration: Bool {
            switch method {
            case .justShowApp:
                return false
            case .switchAccount:
                return true
            }
        }
        
    }
    
}
