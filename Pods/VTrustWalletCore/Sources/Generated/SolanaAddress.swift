// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Solana address helper functions
public final class SolanaAddress: Address {

    /// Returns the address string representation.
    ///
    /// - Parameter address: Non-null pointer to a Solana Address
    /// - Returns: Non-null pointer to the Solana address string representation
    public var description: String {
        return TWStringNSString(TWSolanaAddressDescription(rawValue))
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    public init?(string: String) {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        guard let rawValue = TWSolanaAddressCreateWithString(stringString) else {
            return nil
        }
        self.rawValue = rawValue
    }

    deinit {
        TWSolanaAddressDelete(rawValue)
    }

    /// Derive default token address for token
    ///
    /// - Parameter address: Non-null pointer to a Solana Address
    /// - Parameter tokenMintAddress: Non-null pointer to a token mint address as a string
    /// - Returns: Null pointer if the Default token address for a token is not found, valid pointer otherwise
    public func defaultTokenAddress(tokenMintAddress: String) -> String? {
        let tokenMintAddressString = TWStringCreateWithNSString(tokenMintAddress)
        defer {
            TWStringDelete(tokenMintAddressString)
        }
        guard let result = TWSolanaAddressDefaultTokenAddress(rawValue, tokenMintAddressString) else {
            return nil
        }
        return TWStringNSString(result)
    }

    /// Derive token 2022 address for token
    ///
    /// - Parameter address: Non-null pointer to a Solana Address
    /// - Parameter tokenMintAddress: Non-null pointer to a token mint address as a string
    /// - Returns: Null pointer if the token 2022 address for a token is not found, valid pointer otherwise
    public func token2022Address(tokenMintAddress: String) -> String? {
        let tokenMintAddressString = TWStringCreateWithNSString(tokenMintAddress)
        defer {
            TWStringDelete(tokenMintAddressString)
        }
        guard let result = TWSolanaAddressToken2022Address(rawValue, tokenMintAddressString) else {
            return nil
        }
        return TWStringNSString(result)
    }

}
