// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

/// Non-default coin address derivation names (default, unnamed derivations are not included).
public enum Derivation: UInt32, CaseIterable {
    case `default` = 0
    case custom = 1
    case segwit = 2
    case legacy = 3
    case testnet = 4
    case solana = 5
}
