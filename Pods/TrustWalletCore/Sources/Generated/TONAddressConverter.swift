// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// TON address operations.
public final class TONAddressConverter {

    /// Converts a TON user address into a Bag of Cells (BoC) with a single root Cell.
    /// The function is mostly used to request a Jetton user address via `get_wallet_address` RPC.
    /// https://docs.ton.org/develop/dapps/asset-processing/jettons#retrieving-jetton-wallet-addresses-for-a-given-user
    ///
    /// - Parameter address: Address to be converted into a Bag Of Cells (BoC).
    /// - Returns: Pointer to a base64 encoded Bag Of Cells (BoC). Null if invalid address provided.
    public static func toBoc(address: String) -> String? {
        let addressString = TWStringCreateWithNSString(address)
        defer {
            TWStringDelete(addressString)
        }
        guard let result = TWTONAddressConverterToBoc(addressString) else {
            return nil
        }
        return TWStringNSString(result)
    }

    /// Parses a TON address from a Bag of Cells (BoC) with a single root Cell.
    /// The function is mostly used to parse a Jetton user address received on `get_wallet_address` RPC.
    /// https://docs.ton.org/develop/dapps/asset-processing/jettons#retrieving-jetton-wallet-addresses-for-a-given-user
    ///
    /// - Parameter boc: Base64 encoded Bag Of Cells (BoC).
    /// - Returns: Pointer to a Jetton address.
    public static func fromBoc(boc: String) -> String? {
        let bocString = TWStringCreateWithNSString(boc)
        defer {
            TWStringDelete(bocString)
        }
        guard let result = TWTONAddressConverterFromBoc(bocString) else {
            return nil
        }
        return TWStringNSString(result)
    }

    /// Converts any TON address format to user friendly with the given parameters.
    ///
    /// - Parameter address: raw or user-friendly address to be converted.
    /// - Parameter bounceable: whether the result address should be bounceable.
    /// - Parameter testnet: whether the result address should be testnet.
    /// - Returns: user-friendly address str.
    public static func toUserFriendly(address: String, bounceable: Bool, testnet: Bool) -> String? {
        let addressString = TWStringCreateWithNSString(address)
        defer {
            TWStringDelete(addressString)
        }
        guard let result = TWTONAddressConverterToUserFriendly(addressString, bounceable, testnet) else {
            return nil
        }
        return TWStringNSString(result)
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }


}
