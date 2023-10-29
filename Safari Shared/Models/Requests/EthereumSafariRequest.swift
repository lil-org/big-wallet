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
        let chain: EthereumNetwork?
        let switchToChain: EthereumNetwork?
        let parameters: [String: Any]?
        
        init?(name: String, json: [String: Any]) {
            guard let method = Method(rawValue: name),
                  let address = json["address"] as? String
            else { return nil }
            self.address = address
            self.method = method
            
            if let network = json["networkId"] as? String, let networkId = Int(network) {
                self.chain = EthereumNetwork(rawValue: networkId)
            } else {
                self.chain = nil
            }
            
            let parameters = json["object"] as? [String: Any]
            self.parameters = parameters
            
            if let chainId = parameters?["chainId"] as? String,
               let networkId = Int(hexString: chainId),
               let chain = EthereumNetwork(rawValue: networkId) {
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
