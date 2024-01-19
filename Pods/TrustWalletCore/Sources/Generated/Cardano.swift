// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Cardano helper functions
public struct Cardano {

    /// Calculates the minimum ADA amount needed for a UTXO.
    ///
    /// \deprecated consider using `TWCardanoOutputMinAdaAmount` instead.
    /// - SeeAlso: reference https://docs.cardano.org/native-tokens/minimum-ada-value-requirement
    /// - Parameter tokenBundle: serialized data of TW.Cardano.Proto.TokenBundle.
    /// - Returns: the minimum ADA amount.
    public static func minAdaAmount(tokenBundle: Data) -> UInt64 {
        let tokenBundleData = TWDataCreateWithNSData(tokenBundle)
        defer {
            TWDataDelete(tokenBundleData)
        }
        return TWCardanoMinAdaAmount(tokenBundleData)
    }

    /// Calculates the minimum ADA amount needed for an output.
    ///
    /// - SeeAlso: reference https://docs.cardano.org/native-tokens/minimum-ada-value-requirement
    /// - Parameter toAddress: valid destination address, as string.
    /// - Parameter tokenBundle: serialized data of TW.Cardano.Proto.TokenBundle.
    /// - Parameter coinsPerUtxoByte: cost per one byte of a serialized UTXO (Base-10 decimal string).
    /// - Returns: the minimum ADA amount (Base-10 decimal string).
    public static func outputMinAdaAmount(toAddress: String, tokenBundle: Data, coinsPerUtxoByte: String) -> String? {
        let toAddressString = TWStringCreateWithNSString(toAddress)
        defer {
            TWStringDelete(toAddressString)
        }
        let tokenBundleData = TWDataCreateWithNSData(tokenBundle)
        defer {
            TWDataDelete(tokenBundleData)
        }
        let coinsPerUtxoByteString = TWStringCreateWithNSString(coinsPerUtxoByte)
        defer {
            TWStringDelete(coinsPerUtxoByteString)
        }
        guard let result = TWCardanoOutputMinAdaAmount(toAddressString, tokenBundleData, coinsPerUtxoByteString) else {
            return nil
        }
        return TWStringNSString(result)
    }

    /// Return the staking address associated to (contained in) this address. Must be a Base address.
    /// Empty string is returned on error. Result must be freed.
    /// - Parameter baseAddress: A valid base address, as string.
    /// - Returns: the associated staking (reward) address, as string, or empty string on error.
    public static func getStakingAddress(baseAddress: String) -> String {
        let baseAddressString = TWStringCreateWithNSString(baseAddress)
        defer {
            TWStringDelete(baseAddressString)
        }
        return TWStringNSString(TWCardanoGetStakingAddress(baseAddressString))
    }

    /// Return the legacy(byron) address.
    /// - Parameter publicKey: A valid public key with TWPublicKeyTypeED25519Cardano type.
    /// - Returns: the legacy(byron) address, as string, or empty string on error.
    public static func getByronAddress(publicKey: PublicKey) -> String {
        return TWStringNSString(TWCardanoGetByronAddress(publicKey.rawValue))
    }


    init() {
    }


}
