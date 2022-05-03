// Copyright © 2017-2020 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

public final class PrivateKey {

    public static func isValid(data: Data, curve: Curve) -> Bool {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWPrivateKeyIsValid(dataData, TWCurve(rawValue: curve.rawValue))
    }

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

    public func getPublicKeySecp256k1(compressed: Bool) -> PublicKey {
        return PublicKey(rawValue: TWPrivateKeyGetPublicKeySecp256k1(rawValue, compressed))
    }

    public func getPublicKeyNist256p1() -> PublicKey {
        return PublicKey(rawValue: TWPrivateKeyGetPublicKeyNist256p1(rawValue))
    }

    public func getPublicKeyEd25519() -> PublicKey {
        return PublicKey(rawValue: TWPrivateKeyGetPublicKeyEd25519(rawValue))
    }

    public func getPublicKeyEd25519Blake2b() -> PublicKey {
        return PublicKey(rawValue: TWPrivateKeyGetPublicKeyEd25519Blake2b(rawValue))
    }

    public func getPublicKeyEd25519Extended() -> PublicKey {
        return PublicKey(rawValue: TWPrivateKeyGetPublicKeyEd25519Extended(rawValue))
    }

    public func getPublicKeyCurve25519() -> PublicKey {
        return PublicKey(rawValue: TWPrivateKeyGetPublicKeyCurve25519(rawValue))
    }

    public func getSharedKey(publicKey: PublicKey, curve: Curve) -> Data? {
        guard let result = TWPrivateKeyGetSharedKey(rawValue, publicKey.rawValue, TWCurve(rawValue: curve.rawValue)) else {
            return nil
        }
        return TWDataNSData(result)
    }

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

    public func signAsDER(digest: Data, curve: Curve) -> Data? {
        let digestData = TWDataCreateWithNSData(digest)
        defer {
            TWDataDelete(digestData)
        }
        guard let result = TWPrivateKeySignAsDER(rawValue, digestData, TWCurve(rawValue: curve.rawValue)) else {
            return nil
        }
        return TWDataNSData(result)
    }

    public func signSchnorr(message: Data, curve: Curve) -> Data? {
        let messageData = TWDataCreateWithNSData(message)
        defer {
            TWDataDelete(messageData)
        }
        guard let result = TWPrivateKeySignSchnorr(rawValue, messageData, TWCurve(rawValue: curve.rawValue)) else {
            return nil
        }
        return TWDataNSData(result)
    }

}
