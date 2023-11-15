// Copyright © 2023 Tokenary. All rights reserved.

import Foundation
import WalletCore

struct TransactionInspector {
    
    static let shared = TransactionInspector()
    private init() {}
    
    private let urlSession = URLSession.shared
    
    func interpret(data: String, completion: @escaping (String) -> Void) {
        getMethodSignature(data: data) { signature in
            let decoded = decode(data: data, signature: signature)
            DispatchQueue.main.async { completion(signature) }
        }
    }
    
    // https://github.com/ethereum-lists/4bytes
    private func getMethodSignature(data: String, completion: @escaping (String) -> Void) {
        let length = 8
        let nameHex = data.cleanHex.prefix(length)
        guard nameHex.count == length,
              let url = URL(string: "https://raw.githubusercontent.com/ethereum-lists/4bytes/master/signatures/\(nameHex)")
        else { return }
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
    
    private func decode(data: String, signature: String) -> String {
        // TODO: implement
        return signature + "\n\n" + data
    }
    
}
