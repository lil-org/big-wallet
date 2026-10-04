// ∅ 2026 lil org

extension SafariRequest {
    
    struct Ethereum: Sendable {
        
        enum Method: String, Sendable {
            case signTransaction
            case signPersonalMessage
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
        private let parametersObject: WireProtocol.JSONObject?
        var parameters: [String: Any]? { parametersObject?.json }
        
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
            self.parametersObject = parameters.flatMap { WireProtocol.JSONObject($0) }
            
            if let toChainId = parameters?["chainId"] as? String, let chainId = Int(hexString: toChainId) {
                self.switchToChainId = chainId
            } else {
                self.switchToChainId = nil
            }
        }
    }
    
}
