// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation

struct ResponseToExtension: Codable {
    
    let name: String
    let result: String?
    let results: [String]?
    let error: String?
    
    var json: [String: AnyHashable] {
        if let result = result {
            return ["name": name, "result": result]
        } else if let results = results {
            return ["name": name, "results": results]
        } else if let error = error {
            return ["name": name, "error": error]
        } else {
            return [:]
        }
    }
    
    init(name: String, result: String) {
        self.init(name: name, result: result, results: nil, error: nil)
    }
    
    init(name: String, results: [String]) {
        self.init(name: name, result: nil, results: results, error: nil)
    }
    
    init(name: String, error: String) {
        self.init(name: name, result: nil, results: nil, error: error)
    }
    
    private init(name: String, result: String?, results: [String]?, error: String?) {
        self.name = name
        self.result = result
        self.results = results
        self.error = error
    }
    
}
