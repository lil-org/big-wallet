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
    
    private func getNonceAndBlockhash(account: String, completion: @escaping (((UInt64, String)?) -> Void)) {
        guard let data = Data(hexString: account) else {
            completion(nil)
            return
        }

        let publicKey = "ed25519:" + Base58.encodeNoCheck(data: data)
        let params = [
            "request_type": "view_access_key",
            "finality": "optimistic",
            "account_id": account,
            "public_key": publicKey
        ]
        
        let request = createRequest(method: "query", parameters: params)
        let dataTask = urlSession.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                if let data = data,
                   let response = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any] {
                    let nonce = response["nonce"] as! UInt64
                    let blockhash = response["block_hash"] as! String
                    // TODO: refactor parsing response
                    completion((nonce, blockhash))
                } else {
                    completion(nil)
                }
            }
        }
        dataTask.resume()
        
    }
    
    private func createRequest(method: String, parameters: Any) -> URLRequest {
        var request = URLRequest(url: rpcURL)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"
        
        var dict: [String: Any] = [
            "method": method,
            "id": 1,
            "jsonrpc": "2.0"
        ]
        dict["params"] = parameters
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: dict, options: .fragmentsAllowed)
        return request
    }
    
}
