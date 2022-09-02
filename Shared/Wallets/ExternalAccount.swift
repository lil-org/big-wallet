// Copyright © 2022 Tokenary. All rights reserved.

import WalletCore

struct ExternalAccount {
    
    // TODO: enum that would allow to keep different kinds of data for StarkNet / NEAR / etc.
    // TODO: keep parent account itself here
    
    let address: String // TODO: keep parent address as well
    let parentCoin: CoinType
    let parentDerivation: Derivation
    let parentDerivationPath: String
    let parentPublicKey: String
    let parentExtendedPublicKey: String
    
    var isHidden: Bool
    
    init(parentAccount: Account, nearName: String, isHidden: Bool) {
        self.address = nearName
        self.parentCoin = parentAccount.coin
        self.parentDerivation = parentAccount.derivation
        self.parentDerivationPath = parentAccount.derivationPath
        self.parentPublicKey = parentAccount.publicKey
        self.parentExtendedPublicKey = parentAccount.extendedPublicKey
        self.isHidden = isHidden
    }
    
    init(address: String,
         parentCoin: CoinType,
         parentDerivation: Derivation,
         parentDerivationPath: String,
         parentPublicKey: String,
         parentExtendedPublicKey: String,
         isHidden: Bool) {
        self.address = address
        self.parentCoin = parentCoin
        self.parentDerivation = parentDerivation
        self.parentDerivationPath = parentDerivationPath
        self.parentPublicKey = parentPublicKey
        self.parentExtendedPublicKey = parentExtendedPublicKey
        self.isHidden = isHidden
    }
    
}

extension ExternalAccount: Codable {
    private enum CodingKeys: String, CodingKey {
        case parentCoin
        case address
        case parentDerivation
        case parentDerivationPath
        case parentPublicKey
        case parentExtendedPublicKey
        case isHidden
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(parentCoin.rawValue, forKey: .parentCoin)
        try container.encode(address, forKey: .address)
        try container.encode(parentDerivation.rawValue, forKey: .parentDerivation)
        try container.encode(parentDerivationPath, forKey: .parentDerivationPath)
        try container.encode(parentPublicKey, forKey: .parentPublicKey)
        try container.encode(parentExtendedPublicKey, forKey: .parentExtendedPublicKey)
        try container.encode(isHidden, forKey: .isHidden)
    }
    
    public init(from decoder: Decoder) throws {
        let container               = try decoder.container(keyedBy: CodingKeys.self)
        let rawCoin                 = try container.decode(UInt32.self, forKey: .parentCoin)
        let address                 = try container.decode(String.self, forKey: .address)
        let rawParentDerivation     = try container.decode(UInt32.self, forKey: .parentDerivation)
        let parentDerivationPath    = try container.decode(String.self, forKey: .parentDerivationPath)
        let parentPublicKey         = try container.decode(String.self, forKey: .parentPublicKey)
        let parentExtendedPublicKey = try container.decode(String.self, forKey: .parentExtendedPublicKey)
        let isHidden                = try container.decode(Bool.self, forKey: .isHidden)
        
        self.init(
            address: address,
            parentCoin: CoinType(rawValue: rawCoin)!,
            parentDerivation: Derivation(rawValue: rawParentDerivation)!,
            parentDerivationPath: parentDerivationPath,
            parentPublicKey: parentPublicKey,
            parentExtendedPublicKey: parentExtendedPublicKey,
            isHidden: isHidden
        )
    }
}
