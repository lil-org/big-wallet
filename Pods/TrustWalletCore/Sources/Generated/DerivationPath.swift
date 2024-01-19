// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Represents a BIP44 DerivationPath in C++.
public final class DerivationPath {

    /// Returns the purpose enum of a DerivationPath.
    ///
    /// - Parameter path: DerivationPath to get the purpose of.
    /// - Returns: DerivationPathPurpose.
    public var purpose: Purpose {
        return Purpose(rawValue: TWDerivationPathPurpose(rawValue).rawValue)!
    }

    /// Returns the coin value of a derivation path.
    ///
    /// - Parameter path: DerivationPath to get the coin of.
    /// - Returns: The coin part of the DerivationPath.
    public var coin: UInt32 {
        return TWDerivationPathCoin(rawValue)
    }

    /// Returns the account value of a derivation path.
    ///
    /// - Parameter path: DerivationPath to get the account of.
    /// - Returns: the account part of a derivation path.
    public var account: UInt32 {
        return TWDerivationPathAccount(rawValue)
    }

    /// Returns the change value of a derivation path.
    ///
    /// - Parameter path: DerivationPath to get the change of.
    /// - Returns: The change part of a derivation path.
    public var change: UInt32 {
        return TWDerivationPathChange(rawValue)
    }

    /// Returns the address value of a derivation path.
    ///
    /// - Parameter path: DerivationPath to get the address of.
    /// - Returns: The address part of the derivation path.
    public var address: UInt32 {
        return TWDerivationPathAddress(rawValue)
    }

    /// Returns the string description of a derivation path.
    ///
    /// - Parameter path: DerivationPath to get the address of.
    /// - Returns: The string description of the derivation path.
    public var description: String {
        return TWStringNSString(TWDerivationPathDescription(rawValue))
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    public init(purpose: Purpose, coin: UInt32, account: UInt32, change: UInt32, address: UInt32) {
        rawValue = TWDerivationPathCreate(TWPurpose(rawValue: purpose.rawValue), coin, account, change, address)
    }

    public init?(string: String) {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        guard let rawValue = TWDerivationPathCreateWithString(stringString) else {
            return nil
        }
        self.rawValue = rawValue
    }

    deinit {
        TWDerivationPathDelete(rawValue)
    }

    /// Returns the index component of a DerivationPath.
    ///
    /// - Parameter path: DerivationPath to get the index of.
    /// - Parameter index: The index component of the DerivationPath.
    /// - Returns: DerivationPathIndex or null if index is invalid.
    public func indexAt(index: UInt32) -> DerivationPathIndex? {
        guard let value = TWDerivationPathIndexAt(rawValue, index) else {
            return nil
        }
        return DerivationPathIndex(rawValue: value)
    }

    /// Returns the indices count of a DerivationPath.
    ///
    /// - Parameter path: DerivationPath to get the indices count of.
    /// - Returns: The indices count of the DerivationPath.
    public func indicesCount() -> UInt32 {
        return TWDerivationPathIndicesCount(rawValue)
    }

}
