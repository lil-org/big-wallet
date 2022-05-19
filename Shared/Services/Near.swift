// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import WalletCore

class Near {
    
    enum SendTransactionError: Error {
        case unknown
    }
    
    static let shared = Near()
    private let urlSession = URLSession(configuration: .default)
    private let rpcURL = URL(string: "https://rpc.mainnet.near.org")!
    
    private init() {}
    
    func signAndSendTransaction(privateKey: PrivateKey, completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        
    }
    
    // MARK: - Private
    
    private func createRequest(parameters: [Any]? = nil) -> URLRequest {
        var request = URLRequest(url: rpcURL)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"
        
        var dict: [String: Any] = [
            "method": "query",
            "id": 1,
            "jsonrpc": "2.0"
        ]
        if let parameters = parameters {
            dict["params"] = parameters
        }
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: dict, options: .fragmentsAllowed)
        return request
    }
    
}
