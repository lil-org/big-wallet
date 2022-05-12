// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

extension SafariRequest {
    
    struct Near: SafariRequestBody {
        
        enum Method: String, Decodable, CaseIterable {
            case signIn, signTransactions
        }
        
        let method: Method
        let account: String
        
        init?(name: String, json: [String: Any]) {
            guard let method = Method(rawValue: name),
                  let account = json["account"] as? String else { return nil }
            self.method = method
            self.account = account
        }
        
        var responseUpdatesStoredConfiguration: Bool {
            switch method {
            case .signIn:
                return true
            case .signTransactions:
                return false
            }
        }
        
    }
    
}
