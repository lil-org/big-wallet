// Copyright © 2022 Tokenary. All rights reserved.

import WalletCore

struct ExternalAccount {
    
    let address: String
    let coin: CoinType
    let parentDerivation: Derivation
    let parentDerivationPath: String
    let parentPublicKey: String
    let parentExtendedPublicKey: String
    
}

extension ExternalAccount: Codable {
    private enum CodingKeys: String, CodingKey {
        case coin
        case address
        case parentDerivation
        case parentDerivationPath
        case parentPublicKey
        case parentExtendedPublicKey
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(coin.rawValue, forKey: .coin)
        try container.encode(address, forKey: .address)
        try container.encode(parentDerivation.rawValue, forKey: .parentDerivation)
        try container.encode(parentDerivationPath, forKey: .parentDerivationPath)
        try container.encode(parentPublicKey, forKey: .parentPublicKey)
        try container.encode(parentExtendedPublicKey, forKey: .parentExtendedPublicKey)
    }
    
    public init(from decoder: Decoder) throws {
        let container               = try decoder.container(keyedBy: CodingKeys.self)
        let rawCoin                 = try container.decode(UInt32.self, forKey: .coin)
        let address                 = try container.decode(String.self, forKey: .address)
        let rawParentDerivation     = try container.decode(UInt32.self, forKey: .parentDerivation)
        let parentDerivationPath    = try container.decode(String.self, forKey: .parentDerivationPath)
        let parentPublicKey         = try container.decode(String.self, forKey: .parentPublicKey)
        let parentExtendedPublicKey = try container.decode(String.self, forKey: .parentExtendedPublicKey)
        
        self.init(
            address: address,
            coin: CoinType(rawValue: rawCoin)!,
            parentDerivation: Derivation(rawValue: rawParentDerivation)!,
            parentDerivationPath: parentDerivationPath,
            parentPublicKey: parentPublicKey,
            parentExtendedPublicKey: parentExtendedPublicKey
        )
    }
}
