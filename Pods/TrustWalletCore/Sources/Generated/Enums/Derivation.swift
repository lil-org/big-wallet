// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

/// Non-default coin address derivation names (default, unnamed derivations are not included).
/// Note the enum variant must be sync with `TWDerivation` enum in Rust:
/// https://github.com/trustwallet/wallet-core/blob/master/rust/tw_coin_registry/src/tw_derivation.rs
public enum Derivation: UInt32, CaseIterable {
    case `default` = 0
    case custom = 1
    case bitcoinSegwit = 2
    case bitcoinLegacy = 3
    case bitcoinTestnet = 4
    case litecoinLegacy = 5
    case solanaSolana = 6
    case stratisSegwit = 7
    case bitcoinTaproot = 8
}
