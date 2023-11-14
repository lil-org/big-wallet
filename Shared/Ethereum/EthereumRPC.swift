// Copyright © 2023 Tokenary. All rights reserved.

import Foundation
import WalletCore

private struct RPCResponse: Codable {
    let id: Int
    let jsonrpc: String
    let result: String?
    let error: Error?
    
    struct Error: Codable {
        let code: Int
        let message: String
    }
}

enum EthereumRPCError: Error {
    case serverError(Int, String)
    case unknown
}

class EthereumRPC {
    
    private let queue = DispatchQueue(label: "EthereumRPC")
    private let urlSession = URLSession(configuration: .default)
    private let ensResolver = "0x231b0ee14048e9dccd1d247744d114a4eb5e8e63"
    
    func fetchGasPrice(rpcUrl: String, completion: @escaping (Result<String, Error>) -> Void) {
        request(method: "eth_gasPrice", params: [], rpcUrl: rpcUrl, completion: completion)
    }
    
    func resolveENS(rpcUrl: String, address: String, completion: @escaping (Result<String, Error>) -> Void) {
        unsafeResolveENS(rpcUrl: rpcUrl, address: address) { [weak self] result in
            switch result {
            case .success(let success):
                self?.resolveAddress(rpcUrl: rpcUrl, ens: success) { forwardResult in
                    if case let .success(forward) = forwardResult, forward == address.cleanHex.lowercased() {
                        completion(result)
                    } else {
                        completion(.failure(EthereumRPCError.unknown))
                    }
                }
            case .failure:
                completion(result)
            }
        }
    }
    
    private func unsafeResolveENS(rpcUrl: String, address: String, completion: @escaping (Result<String, Error>) -> Void) {
        let reverseRecord = "\(address.lowercased().cleanHex).addr.reverse"
        let nameHash = namehash(reverseRecord).hexString
        let params: [Any] = [
            [
                "to": ensResolver,
                "data": "0x691f3431" + String(repeating: "0", count: 64 - nameHash.count) + nameHash
            ],
            "latest"
        ]
        request(method: "eth_call", params: params, rpcUrl: rpcUrl) { result in
            switch result {
            case .success(let success):
                if let data = Data(hexString: String(success.cleanHex.dropFirst(64))),
                   let ens = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) {
                    completion(.success(ens))
                } else {
                    completion(.failure(EthereumRPCError.unknown))
                }
            case .failure:
                completion(result)
            }
        }
    }
    
    func resolveAddress(rpcUrl: String, ens: String, completion: @escaping (Result<String, Error>) -> Void) {
        let params: [Any] = [
            [
                "to": ensResolver,
                "data": "0x3b3b57de" + namehash(ens).hexString
            ],
            "latest"
        ]
        request(method: "eth_call", params: params, rpcUrl: rpcUrl) { result in
            switch result {
            case .success(let response):
                let address = String(response.suffix(40))
                if address.contains(where: { $0 != "0" }) {
                    completion(.success(address))
                } else {
                    completion(.failure(EthereumRPCError.unknown))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    func getBalance(rpcUrl: String, for address: String, completion: @escaping (Result<String, Error>) -> Void) {
        request(method: "eth_getBalance", params: [address, "pending"], rpcUrl: rpcUrl, completion: completion)
    }
    
    func fetchNonce(rpcUrl: String, for address: String, completion: @escaping (Result<String, Error>) -> Void) {
        request(method: "eth_getTransactionCount", params: [address, "pending"], rpcUrl: rpcUrl, completion: completion)
    }
    
    func estimateGas(rpcUrl: String, transaction: Transaction, completion: @escaping (Result<String, Error>) -> Void) {
        var dict: [String: Any] = ["from": transaction.from, "to": transaction.to, "data": transaction.data]
        if let gasPrice = transaction.gasPrice { dict["gasPrice"] = gasPrice }
        if let gas = transaction.gas { dict["gas"] = gas }
        if let value = transaction.value, value != String.hexPrefix, value != "0" { dict["value"] = value }
        request(method: "eth_estimateGas", params: [dict], rpcUrl: rpcUrl, completion: completion)
    }
    
    func sendRawTransaction(rpcUrl: String, signedTxData: String, completion: @escaping (Result<String, Error>) -> Void) {
        request(method: "eth_sendRawTransaction", params: [signedTxData], rpcUrl: rpcUrl, completion: completion)
    }
    
    private func request(method: String, params: [Any], rpcUrl: String, retryCount: Int = 0, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: rpcUrl) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let dict: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        request.httpBody = try? JSONSerialization.data(withJSONObject: dict)
        
        let task = urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data, let rpcResponse = try? JSONDecoder().decode(RPCResponse.self, from: data) else {
                if retryCount > 3 {
                    completion(.failure(EthereumRPCError.unknown))
                } else {
                    self?.queue.asyncAfter(deadline: .now() + .milliseconds(500)) {
                        self?.request(method: method, params: params, rpcUrl: rpcUrl, retryCount: retryCount + 1, completion: completion)
                    }
                }
                return
            }
            
            if let result = rpcResponse.result {
                completion(.success(result))
            } else if let error = rpcResponse.error {
                completion(.failure(EthereumRPCError.serverError(error.code, error.message)))
            } else {
                completion(.failure(EthereumRPCError.unknown))
            }
        }
        
        task.resume()
    }
    
    private func namehash(_ name: String) -> Data {
        var node = Data(repeating: 0, count: 32)
        if !name.isEmpty {
            name.split(separator: ".").reversed().forEach { label in
                guard let data = label.data(using: .utf8) else { return }
                node.append(Hash.keccak256(data: data))
                node = Hash.keccak256(data: node)
            }
        }
        return node
    }
    
}
