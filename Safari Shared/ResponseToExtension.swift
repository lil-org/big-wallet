// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

struct ResponseToExtension: Codable {
    
    let id: Int
    let name: String
    let result: String?
    let results: [String]?
    let error: String?
    let chainId: String?
    let rpcURL: String?
    
    var json: [String: AnyHashable] {
        if let data = try? JSONEncoder().encode(self),
           let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: AnyHashable] {
            return dict
        } else {
            return [:]
        }
    }
    
    init(id: Int, name: String, result: String) {
        self.init(id: id, name: name, result: result, results: nil, error: nil, chainId: nil, rpcURL: nil)
    }
    
    init(id: Int, name: String, results: [String], chainId: String, rpcURL: String) {
        self.init(id: id, name: name, result: nil, results: results, error: nil, chainId: chainId, rpcURL: rpcURL)
    }
    
    init(id: Int, name: String, error: String) {
        self.init(id: id, name: name, result: nil, results: nil, error: error, chainId: nil, rpcURL: nil)
    }
    
    private init(id: Int, name: String, result: String?, results: [String]?, error: String?, chainId: String?, rpcURL: String?) {
        self.name = name
        self.result = result
        self.results = results
        self.error = error
        self.chainId = chainId
        self.rpcURL = rpcURL
        self.id = id
    }
    
}
