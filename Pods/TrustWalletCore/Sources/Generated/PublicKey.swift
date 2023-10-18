// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Represents a public key.
public final class PublicKey {

    /// Determines if the given public key is valid or not
    ///
    /// - Parameter data: Non-null block of data representing the public key
    /// - Parameter type: type of the public key
    /// - Returns: true if the block of data is a valid public key, false otherwise
    public static func isValid(data: Data, type: PublicKeyType) -> Bool {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWPublicKeyIsValid(dataData, TWPublicKeyType(rawValue: type.rawValue))
    }

    /// Try to get a public key from a given signature and a message
    ///
    /// - Parameter signature: Non-null pointer to a block of data corresponding to the signature
    /// - Parameter message: Non-null pointer to a block of data corresponding to the message
    /// - Returns: Null pointer if the public key can't be recover from the given signature and message,
    /// pointer to the public key otherwise
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

    /// Determines if the given public key is compressed or not
    ///
    /// - Parameter pk: Non-null pointer to a public key
    /// - Returns: true if the public key is compressed, false otherwise
    public var isCompressed: Bool {
        return TWPublicKeyIsCompressed(rawValue)
    }

    /// Give the compressed public key of the given non-compressed public key
    ///
    /// - Parameter from: Non-null pointer to a non-compressed public key
    /// - Returns: Non-null pointer to the corresponding compressed public-key
    public var compressed: PublicKey {
        return PublicKey(rawValue: TWPublicKeyCompressed(rawValue))
    }

    /// Give the non-compressed public key of a corresponding compressed public key
    ///
    /// - Parameter from: Non-null pointer to the corresponding compressed public key
    /// - Returns: Non-null pointer to the corresponding non-compressed public key
    public var uncompressed: PublicKey {
        return PublicKey(rawValue: TWPublicKeyUncompressed(rawValue))
    }

    /// Gives the raw data of a given public-key
    ///
    /// - Parameter pk: Non-null pointer to a public key
    /// - Returns: Non-null pointer to the raw block of data of the given public key
    public var data: Data {
        return TWDataNSData(TWPublicKeyData(rawValue))
    }

    /// Give the public key type (eliptic) of a given public key
    ///
    /// - Parameter publicKey: Non-null pointer to a public key
    /// - Returns: The public key type of the given public key (eliptic)
    public var keyType: PublicKeyType {
        return PublicKeyType(rawValue: TWPublicKeyKeyType(rawValue).rawValue)!
    }

    /// Get the public key description from a given public key
    ///
    /// - Parameter publicKey: Non-null pointer to a public key
    /// - Returns: Non-null pointer to a string representing the description of the public key
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

    /// Verify the validity of a signature and a message using the given public key
    ///
    /// - Parameter pk: Non-null pointer to a public key
    /// - Parameter signature: Non-null pointer to a block of data corresponding to the signature
    /// - Parameter message: Non-null pointer to a block of data corresponding to the message
    /// - Returns: true if the signature and the message belongs to the given public key, false otherwise
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

    /// Verify the validity as DER of a signature and a message using the given public key
    ///
    /// - Parameter pk: Non-null pointer to a public key
    /// - Parameter signature: Non-null pointer to a block of data corresponding to the signature
    /// - Parameter message: Non-null pointer to a block of data corresponding to the message
    /// - Returns: true if the signature and the message belongs to the given public key, false otherwise
    public func verifyAsDER(signature: Data, message: Data) -> Bool {
        let signatureData = TWDataCreateWithNSData(signature)
        defer {
            TWDataDelete(signatureData)
        }
        let messageData = TWDataCreateWithNSData(message)
        defer {
            TWDataDelete(messageData)
        }
        return TWPublicKeyVerifyAsDER(rawValue, signatureData, messageData)
    }

    /// Verify a Zilliqa schnorr signature with a signature and message.
    ///
    /// - Parameter pk: Non-null pointer to a public key
    /// - Parameter signature: Non-null pointer to a block of data corresponding to the signature
    /// - Parameter message: Non-null pointer to a block of data corresponding to the message
    /// - Returns: true if the signature and the message belongs to the given public key, false otherwise
    public func verifyZilliqaSchnorr(signature: Data, message: Data) -> Bool {
        let signatureData = TWDataCreateWithNSData(signature)
        defer {
            TWDataDelete(signatureData)
        }
        let messageData = TWDataCreateWithNSData(message)
        defer {
            TWDataDelete(messageData)
        }
        return TWPublicKeyVerifyZilliqaSchnorr(rawValue, signatureData, messageData)
    }

}
