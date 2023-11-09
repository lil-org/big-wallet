// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

struct TransactionInspector {
    
    static let shared = TransactionInspector()
    private init() {}
    
    private let urlSession = URLSession.shared
    
    // https://github.com/ethereum-lists/4bytes
    func getMethodName(data: String, completion: @escaping (String) -> Void) {
        let length = 8
        let nameHex = data.cleanHex.prefix(length)
        guard nameHex.count == length,
              let url = URL(string: "https://raw.githubusercontent.com/ethereum-lists/4bytes/master/signatures/\(nameHex)")
        else { return }
        let dataTask = urlSession.dataTask(with: url) { (data, _, _) in
            if let data = data, let name = String(data: data, encoding: .utf8), !name.isEmpty {
                DispatchQueue.main.async { completion(name) }
            }
        }
        dataTask.resume()
    }
    
}
