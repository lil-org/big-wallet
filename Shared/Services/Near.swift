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
    
    func signAndSendTransactions(_ transactions: [String: Any]?, account: Account, privateKey: PrivateKey, completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        guard let array = transactions?["transactions"] as? [[String: Any]], array.count == 1, let tranactionDict = array.first else {
            completion(.failure(.unknown))
            fatalError("oopsie") // TODO: avoid oopsie
        }
        
        //        ["receiverId": wrap.near, "actions": (
        //        {
        //            args =     {
        //                amount = 0;
        //                msg = "";
        //                "receiver_id" = "contract.main.burrow.near";
        //            };
        //            deposit = 1;
        //            gas = 150000000000000;
        //            methodName = "ft_transfer_call";
        //        }
        //        )
        
        let receiverId = tranactionDict["receiverId"] as! String
        let action = (tranactionDict["actions"] as! [[String: Any]])[0] // TODO: support multiple actions
        
        // TODO: in fact there are two actions on burrow
        
        print(tranactionDict)
        print(action)
        
        let deposit = action["deposit"] as! String // TODO: idk https://github.com/trustwallet/wallet-core/blob/a64a483d3725d825dc57141dac2eccbcba693b5e/swift/Tests/Blockchains/NEARTests.swift#L61
        let gas = UInt64(action["gas"] as! String)!
        let methodName = action["methodName"] as! String
        let args = action["args"] as! [String: Any]
        
        // TODO: implement for multiple transactions
        // TODO: let's start with a single transaction
        
        
        // this one gives incorrect length error
//        let functionCall = NEARFunctionCall.with {
//            $0.methodName = methodName.data(using: .utf8)!
//            $0.gas = gas
//            $0.deposit = Data(hex: deposit) // TODO: correctly set deposit value, idk what's the actual input format
//            $0.args = try! JSONSerialization.data(withJSONObject: args, options: .fragmentsAllowed)
//        }
//
        
        
        print(methodName, gas, deposit, args)
        
        let functionCall = NEARFunctionCall.with {
            $0.methodName = methodName.data(using: .utf8)! // TODO: maybe different encoding?
            $0.gas = 30000000000000//gas // TODO: maybe different encoding?
            $0.deposit = Data(hexString: "01000000000000000000000000000000")! // TODO: replace with provided value
            $0.args = Data()//try! JSONSerialization.data(withJSONObject: [], options: .fragmentsAllowed) // TODO: provide valid args as well
        }
        
        
        
        let functionCellAction = NEARAction.with {
            $0.functionCall = functionCall
        }
        
        let actions = [functionCellAction]
        
        // this one works
//        let actions = [
//            NEARAction.with({
//                $0.transfer = NEARTransfer.with {
//                    // uint128_t / little endian byte order
//                    $0.deposit = Data(hexString: "01000000000000000000000000000000")!
//                }
//            })
//        ]
        
        let receiver = receiverId
        
        getNonceAndBlockhash(account: account.address) { [weak self] result in
            guard let result = result else {
                fatalError("meh")
            }
            let nonce = result.0
            let blockhash = result.1
            print(nonce, blockhash)
            
            let signingInput = NEARSigningInput.with {
                $0.nonce = nonce + 1
                $0.actions = actions
                $0.signerID = account.address
                $0.receiverID = receiver
                $0.blockHash = Base58.decodeNoCheck(string: blockhash)!
                $0.privateKey = privateKey.data
            }
            
            let output: NEARSigningOutput = AnySigner.sign(input: signingInput, coin: .near)
            let signedTransaction = output.signedTransaction
            
            print("yo check out signed transaction: ", signedTransaction)
            print(signedTransaction.description)
            
            
            let encoded = signedTransaction.base64EncodedString()
//            let encoded = "CQAAAHRlc3QubmVhcgCRez0mjUtY9/7BsVC9aNab4+5dTMOYVeNBU4Rlu3eGDQEAAAAAAAAADQAAAHdoYXRldmVyLm5lYXIPpHP9JpAd8pa+atxMxN800EDvokNSJLaYaRDmMML+9gEAAAADAQAAAAAAAAAAAAAAAAAAAACWmoMzIYbul1Xkg5MlUlgG4Ymj0tK7S0dg6URD6X4cTyLe7vAFmo6XExAO2m4ZFE2n6KDvflObIHCLodjQIb0B"

            let request = self?.createRequest(method: "broadcast_tx_commit", parameters: [encoded])
            let dataTask = self!.urlSession.dataTask(with: request!) { data, response, error in
                print(data, response, error)
                if let data = data,
                   let response = try? JSONSerialization.jsonObject(with: data) {
                    print(response)
                    print("yay!")
                } else {
                    print("error")
                    fatalError("oopsie")
                }
                
                DispatchQueue.main.async {
                    completion(.failure(.unknown))
                }
            }
            dataTask.resume()
        }
    }
    
    // MARK: - Private
    
    private func getNonceAndBlockhash(account: String, completion: @escaping (((UInt64, String)?) -> Void)) {
        let params = [
            "request_type": "view_access_key",
            "finality": "optimistic",
            "account_id": "4b27c3786133281c7f04c922871b037c572f3002f5fa70358b96228567fd4fd3",
            "public_key": "ed25519:64NkBEiKK72aqE2VyQx3Jg7r24LYEj8JDXJCD9i2k6fU", // TODO: use values from arguments
        ]
        
        let request = createRequest(method: "query", parameters: params)
        let dataTask = urlSession.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                if let data = data,
                   let response = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any] {
                    print(response)
                    let nonce = response["nonce"] as! UInt64
                    let blockhash = response["block_hash"] as! String
                    completion((nonce, blockhash))
                    print("yay!")
                    
                    
//                    {
//                        id = 1;
//                        jsonrpc = "2.0";
//                        result =     {
//                            "block_hash" = HwS99TaG3SHsWhCCtLTLkEw3uVe15yCzrS4Vuw8a2ALv;
//                            "block_height" = 65922634;
//                            nonce = 65363167000015;
//                            permission = FullAccess;
//                        };
//                    }
                    
                    
                    
                    
                } else {
                    print("error")
                    completion(nil)
                    fatalError("oopsie")
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
