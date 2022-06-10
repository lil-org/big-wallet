// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

extension ResponseToExtension {
    
    struct Near: Codable {
        
        let account: String?
        let response: String?
        
        init(account: String? = nil, response: [[String: Any]]? = nil) {
            self.account = account
            if let response = response,
               let responseData = try? JSONSerialization.data(withJSONObject: response, options: .fragmentsAllowed),
               let jsonString = String(data: responseData, encoding: .utf8) {
                self.response = jsonString
            } else {
                self.response = nil
            }
        }
        
    }

}
