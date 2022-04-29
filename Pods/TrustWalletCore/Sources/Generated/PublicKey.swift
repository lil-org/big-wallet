// Copyright © 2017-2020 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

public final class PublicKey {

    public static func isValid(data: Data, type: PublicKeyType) -> Bool {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWPublicKeyIsValid(dataData, TWPublicKeyType(rawValue: type.rawValue))
    }

    public static func recover(signature: Data, message: Data) -> PublicKey? {
        let signatureData = TWDataCreateWithNSData(signature)
        defer {
            TWDataDelete(signatureData)
        }
        let messageData = TWDataCreateWithNSData(message)
        defer {
            TWDataDelete(messageData)
        }
        guard let value = TWPublicKeyRecover(signatureData, messageData) else {
            return nil
        }
        return PublicKey(rawValue: value)
    }

    public var isCompressed: Bool {
        return TWPublicKeyIsCompressed(rawValue)
    }

    public var compressed: PublicKey {
        return PublicKey(rawValue: TWPublicKeyCompressed(rawValue))
    }

    public var uncompressed: PublicKey {
        return PublicKey(rawValue: TWPublicKeyUncompressed(rawValue))
    }

    public var data: Data {
        return TWDataNSData(TWPublicKeyData(rawValue))
    }

    public var keyType: PublicKeyType {
        return PublicKeyType(rawValue: TWPublicKeyKeyType(rawValue).rawValue)!
    }

    public var description: String {
        return TWStringNSString(TWPublicKeyDescription(rawValue))
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    public init?(data: Data, type: PublicKeyType) {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        guard let rawValue = TWPublicKeyCreateWithData(dataData, TWPublicKeyType(rawValue: type.rawValue)) else {
            return nil
        }
        self.rawValue = rawValue
    }

    deinit {
        TWPublicKeyDelete(rawValue)
    }

    public func verify(signature: Data, message: Data) -> Bool {
        let signatureData = TWDataCreateWithNSData(signature)
        defer {
            TWDataDelete(signatureData)
        }
        let messageData = TWDataCreateWithNSData(message)
        defer {
            TWDataDelete(messageData)
        }
        return TWPublicKeyVerify(rawValue, signatureData, messageData)
    }

    public func verifySchnorr(signature: Data, message: Data) -> Bool {
        let signatureData = TWDataCreateWithNSData(signature)
        defer {
            TWDataDelete(signatureData)
        }
        let messageData = TWDataCreateWithNSData(message)
        defer {
            TWDataDelete(messageData)
        }
        return TWPublicKeyVerifySchnorr(rawValue, signatureData, messageData)
    }

}
