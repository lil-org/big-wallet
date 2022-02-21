// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

extension SafariRequest {
    
    struct Solana: SafariRequestBody {
        
        enum Method: String, Decodable, CaseIterable {
            case connect
        }
        
        let method: Method
        
        init?(name: String, json: [String: Any]) {
            guard let method = Method(rawValue: name) else { return nil }
            self.method = method
        }
        
        var responseUpdatesStoredConfiguration: Bool {
            switch method {
            case .connect:
                return true
            }
        }
        
    }
    
}
