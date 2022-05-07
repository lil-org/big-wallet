// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import WalletCore

class Solana {
    
    enum SendTransactionError: Error {
        case blockhashNotFound, unknown
    }
    
    private enum Method: String {
        case sendTransaction, simulateTransaction, getLatestBlockhash
    }
    
    private struct SendTransactionResponse: Codable {
        let result: String?
        private let error: Error?
        
        var blockhashNotFound: Bool {
            return error?.data.err == "BlockhashNotFound"
        }
        
        private struct Error: Codable {
            
            let data: Data
            
            struct Data: Codable {
                let err: String
            }
            
        }
    }
    
    private struct LatestBlockhashResponse: Codable {
        
        let result: Result
        
        struct Result: Codable {
            let value: Value
            
            struct Value: Codable {
                let blockhash: String
            }
        }
    }
    
    static let shared = Solana()
    private let urlSession = URLSession(configuration: .default)
    private let rpcURL = URL(string: "https://api.mainnet-beta.solana.com")!
    
    private init() {}
    
    func sign(message: String, asHex: Bool, privateKey: PrivateKey) -> String? {
        let digest = asHex ? Data(hex: message) : Base58.decodeNoCheck(string: message)
        guard let digest = digest else { return nil }
        if let data = privateKey.sign(digest: digest, curve: CoinType.solana.curve) {
            return Base58.encodeNoCheck(data: data)
        } else {
            return nil
        }
    }
    
    func signAndSendTransaction(retryCount: Int = 0, message: String, options: [String: Any]?, privateKey: PrivateKey, completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        guard retryCount < 3,
              let signed = sign(message: message, asHex: false, privateKey: privateKey),
              let raw = compileTransactionData(message: message, signature: signed, simulation: false) else {
            completion(.failure(.unknown))
            return
        }
        
        sendTransaction(signed: raw, options: options) { [weak self] result in
            switch result {
            case let .success(result):
                completion(.success(result))
            case let .failure(sendTransactionError):
                switch sendTransactionError {
                case .unknown:
                    completion(.failure(.unknown))
                case .blockhashNotFound:
                    self?.updateBlockhash(message: message) { updatedMessage in
                        if let updatedMessage = updatedMessage {
                            self?.signAndSendTransaction(retryCount: retryCount + 1, message: updatedMessage, options: options, privateKey: privateKey, completion: completion)
                        } else {
                            completion(.failure(.unknown))
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Private
    
    private func createRequest(method: Method, parameters: [Any]? = nil) -> URLRequest {
        var request = URLRequest(url: rpcURL)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"
        
        var dict: [String: Any] = [
            "method": method.rawValue,
            "id": 1,
            "jsonrpc": "2.0"
        ]
        if let parameters = parameters {
            dict["params"] = parameters
        }
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: dict, options: .fragmentsAllowed)
        return request
    }
    
    private func getLatestBlockhash(completion: @escaping (String?) -> Void) {
        let request = createRequest(method: .getLatestBlockhash)
        let dataTask = urlSession.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                if let data = data,
                   let response = try? JSONDecoder().decode(LatestBlockhashResponse.self, from: data) {
                    completion(response.result.value.blockhash)
                } else {
                    completion(nil)
                }
            }
        }
        dataTask.resume()
    }
    
    private func sendTransaction(signed: String, options: [String: Any]?, completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        var parameters: [Any] = [signed]
        if let options = options {
            parameters.append(options)
        }
        let request = createRequest(method: .sendTransaction, parameters: parameters)
        let dataTask = urlSession.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                if let data = data,
                   let response = try? JSONDecoder().decode(SendTransactionResponse.self, from: data) {
                    if let result = response.result {
                        completion(.success(result))
                    } else {
                        completion(.failure(response.blockhashNotFound ? .blockhashNotFound : .unknown))
                    }
                } else {
                    completion(.failure(.unknown))
                }
            }
        }
        dataTask.resume()
    }
    
    private func simulateTransaction(serializedMessage: String, signature: String, publicKey: String, completion: @escaping (Any?) -> Void) {
        guard let message = compileTransactionData(message: serializedMessage, signature: signature, simulation: true) else {
            completion(nil)
            return
        }
        
        let configuration: [String: Any] = ["accounts": ["encoding": "jsonParsed", "addresses": [publicKey]]]
        let request = createRequest(method: .simulateTransaction, parameters: [message, configuration])
        
        let dataTask = urlSession.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                if let data = data {
                    let raw = try? JSONSerialization.jsonObject(with: data)
                    completion(raw)
                } else {
                    completion(nil)
                }
            }
        }
        dataTask.resume()
    }
    
    private func compileTransactionData(message: String, signature: String, simulation: Bool) -> String? {
        guard let messageData = Base58.decodeNoCheck(string: message),
              let signatureData = Base58.decodeNoCheck(string: signature) else { return nil }
        let numberOfSignatures = messageData.requiredSignaturesCount
        let placeholderSignature = Data(repeating: 0, count: 64)
        
        var result = Data()
        let encodedSignatureLength = Data.encodeLength(numberOfSignatures)
        result = encodedSignatureLength + (simulation ? placeholderSignature : signatureData)
        
        for _ in 0..<(numberOfSignatures - 1) {
            result += placeholderSignature
        }
        
        result += messageData
        return Base58.encodeNoCheck(data: result)
    }
    
    private func updateBlockhash(message: String, completion: @escaping (String?) -> Void) {
        guard var data = Base58.decodeNoCheck(string: message) else {
            completion(nil)
            return
        }
        
        getLatestBlockhash { blockhash in
            guard let blockhash = blockhash,
                    let numRequiredSignatures = data.popFirst(),
                  let numReadonlySignedAccounts = data.popFirst(),
                  let numReadonlyUnsignedAccounts = data.popFirst(),
                  let blockhashData = Base58.decodeNoCheck(string: blockhash) else {
                completion(nil)
                return
            }
            
            let numberOfBytes = 32
            let accountCount = data.decodeLength()
            let blockhashStartIndex = data.index(data.startIndex, offsetBy: numberOfBytes * accountCount)
            let blockhashEndIndex = data.index(blockhashStartIndex, offsetBy: numberOfBytes)
            data.replaceSubrange(blockhashStartIndex..<blockhashEndIndex, with: blockhashData)
            
            data = Data.encodeLength(accountCount) + data
            data = Data([numRequiredSignatures, numReadonlySignedAccounts, numReadonlyUnsignedAccounts]) + data
            completion(Base58.encodeNoCheck(data: data))
        }
    }
    
}

// https://github.com/p2p-org/solana-swift/blob/main/Sources/SolanaSwift/Extensions/Data%2BExtensions.swift
private extension Data {
    
    var requiredSignaturesCount: Int {
        if let first = first {
            return Int(first)
        } else {
            return 0
        }
    }
    
    var decodedLength: Int {
        var len = 0
        var size = 0
        var bytes = self
        while true {
            guard let elem = bytes.first else { break }
            bytes = bytes.dropFirst()
            len = len | ((Int(elem) & 0x7f) << (size * 7))
            size += 1
            if Int16(elem) & 0x80 == 0 {
                break
            }
        }
        return len
    }
    
    mutating func decodeLength() -> Int {
        var len = 0
        var size = 0
        while true {
            guard let elem = bytes.first else { break }
            _ = popFirst()
            len = len | ((Int(elem) & 0x7f) << (size * 7))
            size += 1
            if Int16(elem) & 0x80 == 0 {
                break
            }
        }
        return len
    }
    
    static func encodeLength(_ len: Int) -> Data {
        encodeLength(UInt(len))
    }
    
    private static func encodeLength(_ len: UInt) -> Data {
        var remLen = len
        var bytes = Data()
        while true {
            var elem = remLen & 0x7f
            remLen = remLen >> 7
            if remLen == 0 {
                bytes.append(UInt8(elem))
                break
            } else {
                elem = elem | 0x80
                bytes.append(UInt8(elem))
            }
        }
        return bytes
    }
    
}
