// ∅ 2024 lil org

import Foundation

extension ResponseToExtension {
    
    struct Ethereum: Codable {
        
        let result: String?
        let results: [String]?
        let chainId: String?
        
        init(result: String) {
            self.init(result: result, results: nil, chainId: nil)
        }
        
        init(results: [String], chainId: String) {
            self.init(result: nil, results: results, chainId: chainId)
        }
        
        private init(result: String?, results: [String]?, chainId: String?) {
            self.result = result
            self.results = results
            self.chainId = chainId
        }
        
    }

}
