// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

struct BundledNetwork: Codable {
    
    let name: String
    let symbol: String
    let isTest: Bool
    
    private enum CodingKeys: String, CodingKey {
        case name = "n"
        case symbol = "s"
        case isTest = "t"
    }
    
    init(name: String, symbol: String, isTest: Bool) {
        self.name = name
        self.symbol = symbol
        self.isTest = isTest
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        symbol = try container.decode(String.self, forKey: .symbol)
        isTest = try container.decodeIfPresent(Bool.self, forKey: .isTest) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(symbol, forKey: .symbol)
        if isTest { try container.encode(isTest, forKey: .isTest) }
    }
    
}
