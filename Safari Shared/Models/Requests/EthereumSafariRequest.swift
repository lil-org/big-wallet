// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

extension SafariRequest {
    
    // Refactor: make codable
    struct Ethereum: SafariRequestBody {
        
        enum Method: String, Decodable, CaseIterable {
            case signTransaction
            case signPersonalMessage
            case signMessage
            case signTypedMessage
            case ecRecover
            case requestAccounts
            case watchAsset
            case addEthereumChain
            case switchEthereumChain
        }
        
        let method: Method
        let address: String
        let chain: EthereumChain?
        let switchToChain: EthereumChain?
        let parameters: [String: Any]?
        
        init?(name: String, json: [String: Any]) {
            guard let method = Method(rawValue: name),
                  let address = json["address"] as? String
            else { return nil }
            self.address = address
            self.method = method
            
            if let network = json["networkId"] as? String, let networkId = Int(network) {
                self.chain = EthereumChain(rawValue: networkId)
            } else {
                self.chain = nil
            }
            
            let parameters = json["object"] as? [String: Any]
            self.parameters = parameters
            
            if let chainId = (parameters?["chainId"] as? String)?.dropFirst(2),
               let networkId = Int(chainId, radix: 16),
               let chain = EthereumChain(rawValue: networkId) {
                self.switchToChain = chain
            } else {
                self.switchToChain = nil
            }
        }
        
        var responseUpdatesStoredConfiguration: Bool {
            switch method {
            case .switchEthereumChain, .addEthereumChain, .requestAccounts:
                return true
            case .ecRecover, .signMessage, .signPersonalMessage, .signTransaction, .signTypedMessage, .watchAsset:
                return false
            }
        }
        
    }
    
}
