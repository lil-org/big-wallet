// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

extension CoinType {
    /// Returns the blockchain for a coin type.
    ///
    /// - Parameter coin: A coin type
    /// - Returns: blockchain associated to the given coin type
    public var blockchain: Blockchain {
        return Blockchain(rawValue: TWCoinTypeBlockchain(TWCoinType(rawValue: rawValue)).rawValue)!
    }
    /// Returns the purpose for a coin type.
    ///
    /// - Parameter coin: A coin type
    /// - Returns: purpose associated to the given coin type
    public var purpose: Purpose {
        return Purpose(rawValue: TWCoinTypePurpose(TWCoinType(rawValue: rawValue)).rawValue)!
    }
    /// Returns the curve that should be used for a coin type.
    ///
    /// - Parameter coin: A coin type
    /// - Returns: curve that should be used for the given coin type
    public var curve: Curve {
        return Curve(rawValue: TWCoinTypeCurve(TWCoinType(rawValue: rawValue)).rawValue)!
    }
    /// Returns the xpub HD version that should be used for a coin type.
    ///
    /// - Parameter coin: A coin type
    /// - Returns: xpub HD version that should be used for the given coin type
    public var xpubVersion: HDVersion {
        return HDVersion(rawValue: TWCoinTypeXpubVersion(TWCoinType(rawValue: rawValue)).rawValue)!
    }
    /// Returns the xprv HD version that should be used for a coin type.
    ///
    /// - Parameter coin: A coin type
    /// - Returns: the xprv HD version that should be used for the given coin type.
    public var xprvVersion: HDVersion {
        return HDVersion(rawValue: TWCoinTypeXprvVersion(TWCoinType(rawValue: rawValue)).rawValue)!
    }
    /// HRP for this coin type
    ///
    /// - Parameter coin: A coin type
    /// - Returns: HRP of the given coin type.
    public var hrp: HRP {
        return HRP(rawValue: TWCoinTypeHRP(TWCoinType(rawValue: rawValue)).rawValue)!
    }
    /// P2PKH prefix for this coin type
    ///
    /// - Parameter coin: A coin type
    /// - Returns: P2PKH prefix for the given coin type
    public var p2pkhPrefix: UInt8 {
        return TWCoinTypeP2pkhPrefix(TWCoinType(rawValue: rawValue))
    }
    /// P2SH prefix for this coin type
    ///
    /// - Parameter coin: A coin type
    /// - Returns: P2SH prefix for the given coin type
    public var p2shPrefix: UInt8 {
        return TWCoinTypeP2shPrefix(TWCoinType(rawValue: rawValue))
    }
    /// Static prefix for this coin type
    ///
    /// - Parameter coin: A coin type
    /// - Returns: Static prefix for the given coin type
    public var staticPrefix: UInt8 {
        return TWCoinTypeStaticPrefix(TWCoinType(rawValue: rawValue))
    }
    /// ChainID for this coin type.
    ///
    /// - Parameter coin: A coin type
    /// - Returns: ChainID for the given coin type.
    /// - Note: Caller must free returned object.
    public var chainId: String {
        return TWStringNSString(TWCoinTypeChainId(TWCoinType(rawValue: rawValue)))
    }
    /// SLIP-0044 id for this coin type
    ///
    /// - Parameter coin: A coin type
    /// - Returns: SLIP-0044 id for the given coin type
    public var slip44Id: UInt32 {
        return TWCoinTypeSlip44Id(TWCoinType(rawValue: rawValue))
    }
    /// SS58Prefix for this coin type
    ///
    /// - Parameter coin: A coin type
    /// - Returns: SS58Prefix for the given coin type
    public var ss58Prefix: UInt32 {
        return TWCoinTypeSS58Prefix(TWCoinType(rawValue: rawValue))
    }
    /// public key type for this coin type
    ///
    /// - Parameter coin: A coin type
    /// - Returns: public key type for the given coin type
    public var publicKeyType: PublicKeyType {
        return PublicKeyType(rawValue: TWCoinTypePublicKeyType(TWCoinType(rawValue: rawValue)).rawValue)!
    }

    /// Validates an address string.
    ///
    /// - Parameter coin: A coin type
    /// - Parameter address: A public address
    /// - Returns: true if the address is a valid public address of the given coin, false otherwise.
    public func validate(address: String) -> Bool {
        let addressString = TWStringCreateWithNSString(address)
        defer {
            TWStringDelete(addressString)
        }
        return TWCoinTypeValidate(TWCoinType(rawValue: rawValue), addressString)
    }


    /// Returns the default derivation path for a particular coin.
    ///
    /// - Parameter coin: A coin type
    /// - Returns: the default derivation path for the given coin type.
    public func derivationPath() -> String {
        return TWStringNSString(TWCoinTypeDerivationPath(TWCoinType(rawValue: rawValue)))
    }


    /// Returns the derivation path for a particular coin with the explicit given derivation.
    ///
    /// - Parameter coin: A coin type
    /// - Parameter derivation: A derivation type
    /// - Returns: the derivation path for the given coin with the explicit given derivation
    public func derivationPathWithDerivation(derivation: Derivation) -> String {
        return TWStringNSString(TWCoinTypeDerivationPathWithDerivation(TWCoinType(rawValue: rawValue), TWDerivation(rawValue: derivation.rawValue)))
    }


    /// Derives the address for a particular coin from the private key.
    ///
    /// - Parameter coin: A coin type
    /// - Parameter privateKey: A valid private key
    /// - Returns: Derived address for the given coin from the private key.
    public func deriveAddress(privateKey: PrivateKey) -> String {
        return TWStringNSString(TWCoinTypeDeriveAddress(TWCoinType(rawValue: rawValue), privateKey.rawValue))
    }


    /// Derives the address for a particular coin from the public key.
    ///
    /// - Parameter coin: A coin type
    /// - Parameter publicKey: A valid public key
    /// - Returns: Derived address for the given coin from the public key.
    public func deriveAddressFromPublicKey(publicKey: PublicKey) -> String {
        return TWStringNSString(TWCoinTypeDeriveAddressFromPublicKey(TWCoinType(rawValue: rawValue), publicKey.rawValue))
    }


    /// Derives the address for a particular coin from the public key with the derivation.
    public func deriveAddressFromPublicKeyAndDerivation(publicKey: PublicKey, derivation: Derivation) -> String {
        return TWStringNSString(TWCoinTypeDeriveAddressFromPublicKeyAndDerivation(TWCoinType(rawValue: rawValue), publicKey.rawValue, TWDerivation(rawValue: derivation.rawValue)))
    }

}
