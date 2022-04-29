// Copyright © 2017-2020 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

extension CoinType {

    public var blockchain: Blockchain {
        return Blockchain(rawValue: TWCoinTypeBlockchain(TWCoinType(rawValue: rawValue)).rawValue)!
    }

    public var purpose: Purpose {
        return Purpose(rawValue: TWCoinTypePurpose(TWCoinType(rawValue: rawValue)).rawValue)!
    }

    public var curve: Curve {
        return Curve(rawValue: TWCoinTypeCurve(TWCoinType(rawValue: rawValue)).rawValue)!
    }

    public var xpubVersion: HDVersion {
        return HDVersion(rawValue: TWCoinTypeXpubVersion(TWCoinType(rawValue: rawValue)).rawValue)!
    }

    public var xprvVersion: HDVersion {
        return HDVersion(rawValue: TWCoinTypeXprvVersion(TWCoinType(rawValue: rawValue)).rawValue)!
    }

    public var hrp: HRP {
        return HRP(rawValue: TWCoinTypeHRP(TWCoinType(rawValue: rawValue)).rawValue)!
    }

    public var p2pkhPrefix: UInt8 {
        return TWCoinTypeP2pkhPrefix(TWCoinType(rawValue: rawValue))
    }

    public var p2shPrefix: UInt8 {
        return TWCoinTypeP2shPrefix(TWCoinType(rawValue: rawValue))
    }

    public var staticPrefix: UInt8 {
        return TWCoinTypeStaticPrefix(TWCoinType(rawValue: rawValue))
    }

    public var slip44Id: UInt32 {
        return TWCoinTypeSlip44Id(TWCoinType(rawValue: rawValue))
    }

    public func validate(address: String) -> Bool {
        let addressString = TWStringCreateWithNSString(address)
        defer {
            TWStringDelete(addressString)
        }
        return TWCoinTypeValidate(TWCoinType(rawValue: rawValue), addressString)
    }


    public func derivationPath() -> String {
        return TWStringNSString(TWCoinTypeDerivationPath(TWCoinType(rawValue: rawValue)))
    }


    public func deriveAddress(privateKey: PrivateKey) -> String {
        return TWStringNSString(TWCoinTypeDeriveAddress(TWCoinType(rawValue: rawValue), privateKey.rawValue))
    }


    public func deriveAddressFromPublicKey(publicKey: PublicKey) -> String {
        return TWStringNSString(TWCoinTypeDeriveAddressFromPublicKey(TWCoinType(rawValue: rawValue), publicKey.rawValue))
    }

}
