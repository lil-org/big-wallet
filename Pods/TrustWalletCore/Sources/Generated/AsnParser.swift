// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
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
