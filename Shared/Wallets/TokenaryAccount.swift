// Copyright © 2022 Tokenary. All rights reserved.

import WalletCore
import BlockiesSwift

final class TokenaryAccount {
    
    private let derivedAccount: Account?
    private let externalAccount: ExternalAccount!
    
    init(derivedAccount: Account) {
        self.derivedAccount = derivedAccount
        self.externalAccount = nil
    }
    
    init(externalAccount: ExternalAccount) {
        self.derivedAccount = nil
        self.externalAccount = externalAccount
    }
    
    var isDerived: Bool {
        return derivedAccount != nil
    }
    
    var address: String {
        if let account = derivedAccount {
            return account.address
        } else {
            return externalAccount.address
        }
    }
    
    var coin: CoinType {
        if let account = derivedAccount {
            return account.coin
        } else {
            return externalAccount.parentCoin
        }
    }
    
    var derivationPath: String {
        if let account = derivedAccount {
            return account.derivationPath
        } else {
            return externalAccount.parentDerivationPath
        }
    }
    
    var derivation: Derivation {
        if let account = derivedAccount {
            return account.derivation
        } else {
            return externalAccount.parentDerivation
        }
    }
    
    var publicKey: String {
        if let account = derivedAccount {
            return account.publicKey
        } else {
            return externalAccount.parentPublicKey
        }
    }
    
    var extendedPublicKey: String {
        if let account = derivedAccount {
            return account.extendedPublicKey
        } else {
            return externalAccount.parentExtendedPublicKey
        }
    }
    
    var shortAddress: String {
        guard isDerived else {
            return address
        }
        
        let dropFirstCount: Int
        switch coin {
        case .ethereum:
            dropFirstCount = 2
        case .near, .solana:
            dropFirstCount = 0
        default:
            fatalError(Strings.somethingWentWrong)
        }
        let withoutCommonPart = String(address.dropFirst(dropFirstCount))
        return withoutCommonPart.prefix(4) + "..." + withoutCommonPart.suffix(4)
    }
    
    var image: Image? {
        if coin == .ethereum {
            return Blockies(seed: address.lowercased()).createImage()
        } else {
            return Images.logo(coin: coin)
        }
    }
    
}

extension TokenaryAccount: Equatable {
    
    public static func == (lhs: TokenaryAccount, rhs: TokenaryAccount) -> Bool {
        return lhs.coin == rhs.coin &&
        lhs.address == rhs.address &&
        lhs.derivation == rhs.derivation &&
        lhs.derivationPath == rhs.derivationPath &&
        lhs.publicKey == rhs.publicKey &&
        lhs.extendedPublicKey == rhs.extendedPublicKey
    }
    
}

extension TokenaryAccount: Hashable {
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(coin)
        hasher.combine(address)
        hasher.combine(derivation)
        hasher.combine(derivationPath)
        hasher.combine(publicKey)
        hasher.combine(extendedPublicKey)
    }
    
}
