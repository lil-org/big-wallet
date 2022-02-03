// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

struct SafariRequest {
    
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
        case switchAccount
    }
    
    private let json: [String: Any]
    
    let method: Method
    let id: Int
    let address: String
    let host: String?
    private let favicon: String?
    
    var iconURLString: String? {
        if let host = host, let favicon = favicon {
            if favicon.first == "/" {
                return "https://" + host + favicon
            } else if favicon.first == "." {
                return "https://" + host + favicon.dropFirst()
            }
        }
        return nil
    }
    
    init?(query: String) {
        guard let parametersString = query.removingPercentEncoding,
              let data = parametersString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else { return nil }
        guard let name = json["name"] as? String,
              let method = Method(rawValue: name),
              let id = json["id"] as? Int,
              let address = json["address"] as? String
        else { return nil }
        
        self.json = json
        self.method = method
        self.id = id
        self.address = address
        self.host = json["host"] as? String
        self.favicon = json["favicon"] as? String
    }
    
    var parameters: [String: Any]? {
        return json["object"] as? [String: Any]
    }
    
    var name: String {
        return method.rawValue
    }
    
    var chain: EthereumChain? {
        if let network = json["networkId"] as? String, let networkId = Int(network) {
            return EthereumChain(rawValue: networkId)
        } else {
            return nil
        }
    }
    
    var chainInfo: (chainId: String, name: String, rpcURLs: [String])? {
        if let chainId = parameters?["chainId"] as? String,
           let name = parameters?["chainName"] as? String,
           let urls = parameters?["rpcUrls"] as? [String] {
            return (chainId: chainId, name: name, rpcURLs: urls)
        } else {
            return nil
        }
    }
    
    var switchToChain: EthereumChain? {
        if let chainId = (parameters?["chainId"] as? String)?.dropFirst(2),
           let networkId = Int(chainId, radix: 16),
           let chain = EthereumChain(rawValue: networkId) {
            return chain
        } else {
            return nil
        }
    }
    
}
