// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Represents an ASN.1 DER parser.
public struct AsnParser {

    /// Parses the given ECDSA signature from ASN.1 DER encoded bytes.
    ///
    /// - Parameter encoded: The ASN.1 DER encoded signature.
    /// - Returns: The ECDSA signature standard binary representation: RS, where R - 32 byte array, S - 32 byte array.
    public static func ecdsaSignatureFromDer(encoded: Data) -> Data? {
        let encodedData = TWDataCreateWithNSData(encoded)
        defer {
            TWDataDelete(encodedData)
        }
        guard let result = TWAsnParserEcdsaSignatureFromDer(encodedData) else {
            return nil
        }
        return TWDataNSData(result)
    }


    init() {
    }


}
