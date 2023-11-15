// Copyright © 2023 Tokenary. All rights reserved.

import Foundation
import WalletCore

struct TransactionInspector {
    
    static let shared = TransactionInspector()
    private init() {}
    
    private let urlSession = URLSession.shared
    
    func interpret(data: String, completion: @escaping (String) -> Void) {
        let length = 8
        let nameHex = String(data.cleanHex.prefix(length))
        guard nameHex.count == length else {return}
        
        getMethodSignature(nameHex: nameHex) { signature in
            let decoded = decode(data: data, nameHex: nameHex, signature: signature)
            let result = decoded ?? (signature + "\n\n" + data)
            DispatchQueue.main.async { completion(result) }
        }
    }
    
    // https://github.com/ethereum-lists/4bytes
    private func getMethodSignature(nameHex: String, completion: @escaping (String) -> Void) {
        guard let url = URL(string: "https://raw.githubusercontent.com/ethereum-lists/4bytes/master/signatures/\(nameHex)") else { return }
        let dataTask = urlSession.dataTask(with: url) { (data, response, error) in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error == nil,
               (200...299).contains(statusCode),
               let data = data,
               let sig = String(data: data, encoding: .utf8),
               !sig.isEmpty {
                completion(sig)
            }
        }
        dataTask.resume()
    }
    
    private func decode(data: String, nameHex: String, signature: String) -> String? {
        guard let start = signature.firstIndex(of: "("), signature.hasSuffix(")") else { return nil }
        let name = signature.prefix(upTo: start)
        let args = String(signature.dropFirst(name.count + 1).dropLast())
        
        let inputs = [Any]() // TODO: implement
        
        let dict: [String: Any] = ["inputs": inputs, "name": name]
        let abi = [nameHex: dict]
        if let abiData = try? JSONSerialization.data(withJSONObject: abi),
           let abiString = String(data: abiData, encoding: .utf8),
           let callData = Data(hexString: data),
           let decoded = EthereumAbi.decodeCall(data: callData, abi: abiString) {
            let json = try! JSONSerialization.jsonObject(with: decoded.data(using: .utf8)!) // TODO: make a good string
            print(json)
            return decoded
        } else {
            return nil
        }
    }
    
}
