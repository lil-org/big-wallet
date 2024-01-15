// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

/// Stellar network passphrase string.
public enum StellarPassphrase: UInt32, CaseIterable, CustomStringConvertible  {
    case stellar = 0
    case kin = 1

    public var description: String {
        switch self {
        case .stellar: return "Public Global Stellar Network ; September 2015"
        case .kin: return "Kin Mainnet ; December 2018"
        }
    }
}
