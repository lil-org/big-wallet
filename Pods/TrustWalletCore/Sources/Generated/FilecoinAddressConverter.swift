// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Filecoin-Ethereum address converter.
public struct FilecoinAddressConverter {

    /// Converts a Filecoin address to Ethereum.
    ///
    /// - Parameter filecoinAddress:: a Filecoin address.
    /// - Returns:s the Ethereum address. On invalid input empty string is returned. Returned object needs to be deleted after use.
    public static func convertToEthereum(filecoinAddress: String) -> String {
        let filecoinAddressString = TWStringCreateWithNSString(filecoinAddress)
        defer {
            TWStringDelete(filecoinAddressString)
        }
        return TWStringNSString(TWFilecoinAddressConverterConvertToEthereum(filecoinAddressString))
    }

    /// Converts an Ethereum address to Filecoin.
    ///
    /// - Parameter ethAddress:: an Ethereum address.
    /// - Returns:s the Filecoin address. On invalid input empty string is returned. Returned object needs to be deleted after use.
    public static func convertFromEthereum(ethAddress: String) -> String {
        let ethAddressString = TWStringCreateWithNSString(ethAddress)
        defer {
            TWStringDelete(ethAddressString)
        }
        return TWStringNSString(TWFilecoinAddressConverterConvertFromEthereum(ethAddressString))
    }


    init() {
    }


}
