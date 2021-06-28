// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation

struct GasService {
    
    struct Info: Codable {
        let standard: Int
        let slow: Int
        let fast: Int
        let rapid: Int
    }
    
    static let shared = GasService()
    private init() {}
    
    var currentInfo: Info?
    
    func start() {
        
    }
    
}
