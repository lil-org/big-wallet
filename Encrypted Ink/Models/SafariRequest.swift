// Copyright © 2021 Encrypted Ink. All rights reserved.

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
    }
    
    private let json: [String: Any]
    
    let method: Method
    let id: Int
    let address: String
    
    init?(query: String) {
        guard let parametersString = query.removingPercentEncoding,
              let data = parametersString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else { return nil }
        
        guard let name = json["name"] as? String,
              let method = Method(rawValue: name),
              let id = json["id"] as? Int,
              let addrerss = json["address"] as? String
        else { return nil }
        
        self.json = json
        self.method = method
        self.id = id
        self.address = addrerss
    }
    
    private var parameters: [String: Any]? {
        return json["object"] as? [String: Any]
    }
    
    var message: Data? {
        if let hexString = parameters?["data"] as? String,
           let data = Data(hexString: hexString) {
            return data
        } else {
            return nil
        }
    }
    
    var signatureAndMessage: (signature: Data, message: Data)? {
        if let signatureHexString = parameters?["signature"] as? String,
           let signatureData = Data(hexString: signatureHexString),
           let messageHexString = parameters?["message"] as? String,
           let messageData = Data(hexString: messageHexString) {
            return (signatureData, messageData)
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

    var raw: String? {
        return parameters?["raw"] as? String
    }
    
}
