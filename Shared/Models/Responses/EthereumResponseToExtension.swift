// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

extension ResponseToExtension {
    
    struct Ethereum: Codable {
        
        let result: String?
        let results: [String]?
        let chainId: String?
        let rpcURL: String?
        
        init(result: String) {
            self.init(result: result, results: nil, chainId: nil, rpcURL: nil)
        }
        
        init(results: [String], chainId: String, rpcURL: String) {
            self.init(result: nil, results: results, chainId: chainId, rpcURL: rpcURL)
        }
        
        private init(result: String?, results: [String]?, chainId: String?, rpcURL: String?) {
            self.result = result
            self.results = results
            self.chainId = chainId
            self.rpcURL = rpcURL
        }
        
    }

}
