// ∅ 2026 lil org

extension SafariRequest {
    
    struct Ethereum: SafariRequestBody {
        
        enum Method: String {
            case signTransaction
            case signPersonalMessage
            case signMessage
            case signTypedMessage
            case ecRecover
            case requestAccounts
            case addEthereumChain
            case switchEthereumChain
        }
        
        let method: Method
        let address: String
        let currentChainId: Int?
        let switchToChainId: Int?
        let parameters: [String: Any]?
        
        init?(name: String, json: [String: Any]) {
            guard let method = Method(rawValue: name),
                  let address = json["address"] as? String
            else { return nil }
            self.address = address
            self.method = method
            
            if let currentChainId = json["chainId"] as? String, let chainId = Int(hexString: currentChainId) {
                self.currentChainId = chainId
            } else {
                self.currentChainId = nil
            }
            
            let parameters = json["object"] as? [String: Any]
            self.parameters = parameters
            
            if let toChainId = parameters?["chainId"] as? String, let chainId = Int(hexString: toChainId) {
                self.switchToChainId = chainId
            } else {
                self.switchToChainId = nil
            }
        }
        
        var responseUpdatesStoredConfiguration: Bool {
            switch method {
            case .switchEthereumChain, .addEthereumChain, .requestAccounts:
                return true
            case .ecRecover, .signMessage, .signPersonalMessage, .signTransaction, .signTypedMessage:
                return false
            }
        }
        
    }
    
}
