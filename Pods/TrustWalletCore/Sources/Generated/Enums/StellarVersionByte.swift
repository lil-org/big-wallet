// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

/// Stellar address version byte.
public enum StellarVersionByte: UInt16, CaseIterable {
    case accountID = 0x30
    case seed = 0xc0
    case preAuthTX = 0xc8
    case sha256Hash = 0x118
}
