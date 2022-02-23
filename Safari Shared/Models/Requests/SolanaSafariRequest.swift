// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

extension SafariRequest {
    
    struct Solana: SafariRequestBody {
        
        enum Method: String, Decodable, CaseIterable {
            case connect, signMessage
        }
        
        let method: Method
        let publicKey: String
        let parameters: [String: Any]?
        
        init?(name: String, json: [String: Any]) {
            guard let method = Method(rawValue: name),
                  let publicKey = json["publicKey"] as? String else { return nil }
            self.method = method
            self.publicKey = publicKey
            let parameters = json["object"] as? [String: Any]
            self.parameters = parameters
        }
        
        var responseUpdatesStoredConfiguration: Bool {
            switch method {
            case .connect:
                return true
            case .signMessage:
                return false
            }
        }
        
    }
    
}
