// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

/// Bitcoin SIGHASH type.
public enum BitcoinSigHashType: UInt32, CaseIterable {
    case all = 0x01
    case none = 0x02
    case single = 0x03
    case fork = 0x40
    case forkBTG = 0x4f40
}
