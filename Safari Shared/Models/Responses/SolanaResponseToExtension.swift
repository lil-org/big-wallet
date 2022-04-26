// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

extension ResponseToExtension {
    
    struct Solana: Codable {
        
        let publicKey: String?
        let result: String?
        let results: [String]?
        
        init(publicKey: String? = nil, result: String? = nil, results: [String]? = nil) {
            self.publicKey = publicKey
            self.result = result
            self.results = results
        }
        
    }

}
