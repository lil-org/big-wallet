// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

extension SafariRequest {
    
    struct Near: SafariRequestBody {
        
        enum Method: String, Decodable, CaseIterable {
            case signIn, signAndSendTransactions
        }
        
        struct SignInRequest {
            let contractId: String
            let methodNames: [String]?
        }
        
        let method: Method
        let account: String
        let signInRequest: SignInRequest?
        
        let params: [String: Any]? // TODO: do not keep params, decode right away
        
        init?(name: String, json: [String: Any]) {
            guard let method = Method(rawValue: name),
                  let account = json["account"] as? String else { return nil }
            self.method = method
            self.account = account
            
            let parameters = (json["object"] as? [String: Any])?["params"] as? [String: Any]
            self.params = parameters
            
            // TODO: what if there is a contractId, but it is not a sign in request
            if let contractId = parameters?["contractId"] as? String {
                self.signInRequest = SignInRequest(contractId: contractId, methodNames: parameters?["methodNames"] as? [String])
            } else {
                self.signInRequest = nil
            }
        }
        
        var responseUpdatesStoredConfiguration: Bool {
            switch method {
            case .signIn:
                return true
            case .signAndSendTransactions:
                return false
            }
        }
        
    }
    
}
