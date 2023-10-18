// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Represents a private key.
public final class PrivateKey {

    /// Determines if the given private key is valid or not.
    ///
    /// - Parameter data: block of data (private key bytes)
    /// - Parameter curve: Eliptic curve of the private key
    /// - Returns: true if the private key is valid, false otherwise
    public static func isValid(data: Data, curve: Curve) -> Bool {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWPrivateKeyIsValid(dataData, TWCurve(rawValue: curve.rawValue))
    }

    /// Convert the given private key to raw-bytes block of data
    ///
    /// - Parameter pk: Non-null pointer to the private key
    /// - Returns: Non-null block of data (raw bytes) of the given private key
    public var data: Data {
        return TWDataNSData(TWPrivateKeyData(rawValue))
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = TWPrivateKeyCreate()
    }

    public init?(data: Data) {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        guard let rawValue = TWPrivateKeyCreateWithData(dataData) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init?(key: PrivateKey) {
        guard let rawValue = TWPrivateKeyCreateCopy(key.rawValue) else {
            return nil
        }
        self.rawValue = rawValue
    }

    deinit {
        TWPrivateKeyDelete(rawValue)
    }

    /// Returns the public key associated with the given coinType and privateKey
    ///
    /// - Parameter pk: Non-null pointer to the private key
    /// - Parameter coinType: coinType of the given private key
    /// - Returns: Non-null pointer to the corresponding public key
    public func getPublicKey(coinType: CoinType) -> PublicKey {
        return PublicKey(rawValue: TWPrivateKeyGetPublicKey(rawValue, TWCoinType(rawValue: coinType.rawValue)))
    }

    /// Returns the public key associated with the given pubkeyType and privateKey
    ///
    /// - Parameter pk: Non-null pointer to the private key
    /// - Parameter pubkeyType: pubkeyType of the given private key
    /// - Returns: Non-null pointer to the corresponding public key
    public func getPublicKeyByType(pubkeyType: PublicKeyType) -> PublicKey {
        return PublicKey(rawValue: TWPrivateKeyGetPublicKeyByType(rawValue, TWPublicKeyType(rawValue: pubkeyType.rawValue)))
    }

    /// Returns the Secp256k1 public key associated with the given private key
    ///
    /// - Parameter pk: Non-null pointer to the private key
    /// - Parameter compressed: if the given private key is compressed or not
    /// - Returns: Non-null pointer to the corresponding public key
    public func getPublicKeySecp256k1(compressed: Bool) -> PublicKey {
        return PublicKey(rawValue: TWPrivateKeyGetPublicKeySecp256k1(rawValue, compressed))
    }

    /// Returns the Nist256p1 public key associated with the given private key
    ///
    /// - Parameter pk: Non-null pointer to the private key
    /// - Returns: Non-null pointer to the corresponding public key
    public func getPublicKeyNist256p1() -> PublicKey {
        return PublicKey(rawValue: TWPrivateKeyGetPublicKeyNist256p1(rawValue))
    }

    /// Returns the Ed25519 public key associated with the given private key
    ///
    /// - Parameter pk: Non-null pointer to the private key
    /// - Returns: Non-null pointer to the corresponding public key
    public func getPublicKeyEd25519() -> PublicKey {
        return PublicKey(rawValue: TWPrivateKeyGetPublicKeyEd25519(rawValue))
    }

    /// Returns the Ed25519Blake2b public key associated with the given private key
    ///
    /// - Parameter pk: Non-null pointer to the private key
    /// - Returns: Non-null pointer to the corresponding public key
    public func getPublicKeyEd25519Blake2b() -> PublicKey {
        return PublicKey(rawValue: TWPrivateKeyGetPublicKeyEd25519Blake2b(rawValue))
    }

    /// Returns the Ed25519Cardano public key associated with the given private key
    ///
    /// - Parameter pk: Non-null pointer to the private key
    /// - Returns: Non-null pointer to the corresponding public key
    public func getPublicKeyEd25519Cardano() -> PublicKey {
        return PublicKey(rawValue: TWPrivateKeyGetPublicKeyEd25519Cardano(rawValue))
    }

    /// Returns the Curve25519 public key associated with the given private key
    ///
    /// - Parameter pk: Non-null pointer to the private key
    /// - Returns: Non-null pointer to the corresponding public key
    public func getPublicKeyCurve25519() -> PublicKey {
        return PublicKey(rawValue: TWPrivateKeyGetPublicKeyCurve25519(rawValue))
    }

    /// Signs a digest using ECDSA and given curve.
    ///
    /// - Parameter pk:  Non-null pointer to a Private key
    /// - Parameter digest: Non-null digest block of data
    /// - Parameter curve: Eliptic curve
    /// - Returns: Signature as a Non-null block of data
    public func sign(digest: Data, curve: Curve) -> Data? {
        let digestData = TWDataCreateWithNSData(digest)
        defer {
            TWDataDelete(digestData)
        }
        guard let result = TWPrivateKeySign(rawValue, digestData, TWCurve(rawValue: curve.rawValue)) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Signs a digest using ECDSA. The result is encoded with DER.
    ///
    /// - Parameter pk:  Non-null pointer to a Private key
    /// - Parameter digest: Non-null digest block of data
    /// - Returns: Signature as a Non-null block of data
    public func signAsDER(digest: Data) -> Data? {
        let digestData = TWDataCreateWithNSData(digest)
        defer {
            TWDataDelete(digestData)
        }
        guard let result = TWPrivateKeySignAsDER(rawValue, digestData) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Signs a digest using ECDSA and Zilliqa schnorr signature scheme.
    ///
    /// - Parameter pk: Non-null pointer to a Private key
    /// - Parameter message: Non-null message
    /// - Returns: Signature as a Non-null block of data
    public func signZilliqaSchnorr(message: Data) -> Data? {
        let messageData = TWDataCreateWithNSData(message)
        defer {
            TWDataDelete(messageData)
        }
        guard let result = TWPrivateKeySignZilliqaSchnorr(rawValue, messageData) else {
            return nil
        }
        return TWDataNSData(result)
    }

}
