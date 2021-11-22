// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation

struct ResponseToExtension: Codable {
    
    let result: String?
    let results: [String]?
    let error: String?
    let setAddress: Bool?
    
    var json: [String: AnyHashable] {
        if let result = result {
            return ["result": result]
        } else if let results = results {
            return ["results": results, "setAddress": setAddress ?? false]
        } else if let error = error {
            return ["error": error]
        } else {
            return [:]
        }
    }
    
    init(result: String) {
        self.init(result: result, results: nil, error: nil, setAddress: nil)
    }
    
    init(results: [String], setAddress: Bool) {
        self.init(result: nil, results: results, error: nil, setAddress: setAddress)
    }
    
    init(error: String) {
        self.init(result: nil, results: nil, error: error, setAddress: nil)
    }
    
    private init(result: String?, results: [String]?, error: String?, setAddress: Bool?) {
        self.result = result
        self.results = results
        self.error = error
        self.setAddress = setAddress
    }
    
}
