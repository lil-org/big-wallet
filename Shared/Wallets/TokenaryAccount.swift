// Copyright © 2022 Tokenary. All rights reserved.

import WalletCore
import BlockiesSwift

final class TokenaryAccount {
    
    private let derivedAccount: Account?
    
    init(derivedAccount: Account?) {
        // TODO: be able to create non derived account as well
        self.derivedAccount = derivedAccount
    }
    
    var isDerived: Bool {
        return derivedAccount != nil
    }
    
    var address: String {
        if let account = derivedAccount {
            return account.address
        } else {
            // TODO: return additionally stored value
            return ""
        }
    }
    
    var coin: CoinType {
        if let account = derivedAccount {
            return account.coin
        } else {
            // TODO: return additionally stored value
            return CoinType.near
        }
    }
    
    var derivationPath: String {
        if let account = derivedAccount {
            return account.derivationPath
        } else {
            // TODO: return additionally stored value
            return ""
        }
    }
    
    var derivation: Derivation {
        if let account = derivedAccount {
            return account.derivation
        } else {
            // TODO: return additionally stored value
            // for now it should just copy Derivation of parent Account
            return .custom
        }
    }
    
    var publicKey: String {
        if let account = derivedAccount {
            return account.publicKey
        } else {
            // TODO: return additionally stored value
            return ""
        }
    }
    
    var shortAddress: String {
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
        lhs.publicKey == rhs.publicKey
    }
    
}

extension TokenaryAccount: Hashable {
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(coin)
        hasher.combine(address)
        hasher.combine(derivation)
        hasher.combine(derivationPath)
        hasher.combine(publicKey)
    }
    
}
