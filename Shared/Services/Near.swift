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
    
    func signAndSendTransactions(_ transactions: [[String: Any]],
                                 account: Account,
                                 privateKey: PrivateKey,
                                 completion: @escaping (Result<[[String: Any]], SendTransactionError>) -> Void) {
        signAndSendRemainingTransactions(transactions, receivedResponses: [], account: account, privateKey: privateKey, completion: completion)
    }
    
    // MARK: - Private
    
    private func signAndSendRemainingTransactions(_ transactions: [[String: Any]],
                                                  receivedResponses: [[String: Any]],
                                                  account: Account,
                                                  privateKey: PrivateKey,
                                                  completion: @escaping (Result<[[String: Any]], SendTransactionError>) -> Void) {
        let transaction = transactions[0]
        let remainingTransactions = transactions.dropFirst()
        guard let receiverId = transaction["receiverId"] as? String,
              let actionsDicts = transaction["actions"] as? [[String: Any]] else {
            completion(.failure(.unknown))
            return
        }
        
        var actions = [NEARAction]()
        for action in actionsDicts {
            guard let deposit = action["deposit"] as? String,
                  let gasString = action["gas"] as? String,
                  let gas = UInt64(gasString),
                  let methodName = action["methodName"] as? String,
                  let args = action["args"] as? [String: Any],
                  let argsData = try? JSONSerialization.data(withJSONObject: args, options: .fragmentsAllowed),
                  let uintDeposit = UInt128.fromString(deposit) else {
                completion(.failure(.unknown))
                return
            }
            
            let data = Data(withUnsafeBytes(of: uintDeposit.littleEndian) { Array($0) })
            let functionCall = NEARFunctionCall.with {
                $0.methodName = methodName
                $0.gas = gas
                $0.deposit = data
                $0.args = args.isEmpty ? Data() : argsData
            }
            
            let functionCallAction = NEARAction.with {
                $0.functionCall = functionCall
            }
            
            actions.append(functionCallAction)
        }
        
        getNonceAndBlockhash(account: account.address) { [weak self] result in
            guard let result = result, let blockhash = Base58.decodeNoCheck(string: result.1) else {
                DispatchQueue.main.async {
                    completion(.failure(.unknown))
                }
                return
            }
            
            let signingInput = NEARSigningInput.with {
                $0.nonce = result.0 + 1
                $0.actions = actions
                $0.signerID = account.address
                $0.receiverID = receiverId
                $0.blockHash = blockhash
                $0.privateKey = privateKey.data
            }
            
            let output: NEARSigningOutput = AnySigner.sign(input: signingInput, coin: .near)
            let signedTransaction = output.signedTransaction
            let encoded = signedTransaction.base64EncodedString()
            let hash = Base58.encodeNoCheck(data: output.hash)
            self?.sendTransaction(encoded,
                                  hash: hash,
                                  remainingTransactions: Array(remainingTransactions),
                                  receivedResponses: receivedResponses,
                                  account: account,
                                  privateKey: privateKey,
                                  completion: completion)
        }
    }
    
    private func sendTransaction(_ transaction: String,
                                 hash: String,
                                 remainingTransactions: [[String: Any]],
                                 receivedResponses: [[String: Any]],
                                 account: Account,
                                 privateKey: PrivateKey,
                                 completion: @escaping (Result<[[String: Any]], SendTransactionError>) -> Void) {
        let request = createRequest(method: "broadcast_tx_commit", parameters: [transaction])
        let dataTask = urlSession.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    completion(.failure(.unknown))
                }
                return
            }
            
            guard let result = response["result"] as? [String: Any] else {
                if ((response["error"] as? [String: Any])?["cause"] as? [String: Any])?["name"] as? String == "TIMEOUT_ERROR" {
                    self?.getTransactionResult(hash: hash, account: account) { result in
                        switch result {
                        case .failure:
                            completion(.failure(.unknown))
                        case let .success(result):
                            let responses = receivedResponses + [result]
                            if remainingTransactions.isEmpty {
                                completion(.success(responses))
                            } else {
                                self?.signAndSendRemainingTransactions(remainingTransactions,
                                                                       receivedResponses: responses,
                                                                       account: account,
                                                                       privateKey: privateKey,
                                                                       completion: completion)
                            }
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        completion(.failure(.unknown))
                    }
                }
                
                return
            }
                        
            let responses = receivedResponses + [result]
            DispatchQueue.main.async {
                if remainingTransactions.isEmpty {
                    completion(.success(responses))
                } else {
                    self?.signAndSendRemainingTransactions(remainingTransactions,
                                                           receivedResponses: responses,
                                                           account: account,
                                                           privateKey: privateKey,
                                                           completion: completion)
                }
            }
        }
        dataTask.resume()
    }
    
    private func getTransactionResult(hash: String, account: Account, retryCount: Int = 0, completion: @escaping (Result<[String: Any], SendTransactionError>) -> Void) {
        let request = createRequest(method: "tx", parameters: [hash, account.address])
        let dataTask = urlSession.dataTask(with: request) { data, _, _ in
            if let data = data,
               let result = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any] {
                DispatchQueue.main.async {
                    completion(.success(result))
                }
            } else if retryCount < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                    self?.getTransactionResult(hash: hash, account: account, retryCount: retryCount + 1, completion: completion)
                }
            } else {
                DispatchQueue.main.async {
                    completion(.failure(.unknown))
                }
            }
        }
        dataTask.resume()
    }
    
    private func getNonceAndBlockhash(account: String, retryCount: Int = 0, completion: @escaping (((UInt64, String)?) -> Void)) {
        guard let publicKeyData = Data(hexString: account) else {
            completion(nil)
            return
        }

        let publicKey = "ed25519:" + Base58.encodeNoCheck(data: publicKeyData)
        let params = [
            "request_type": "view_access_key",
            "finality": "optimistic",
            "account_id": account,
            "public_key": publicKey
        ]
        
        let request = createRequest(method: "query", parameters: params)
        let dataTask = urlSession.dataTask(with: request) { data, _, _ in
            if let data = data,
               let result = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any],
               let nonce = result["nonce"] as? UInt64,
               let blockhash = result["block_hash"] as? String {
                completion((nonce, blockhash))
            } else if retryCount < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                    self?.getNonceAndBlockhash(account: account, retryCount: retryCount + 1, completion: completion)
                }
            } else {
                completion(nil)
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
