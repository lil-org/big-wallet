// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

/// Non-default coin address derivation names (default, unnamed derivations are not included).
public enum Derivation: UInt32, CaseIterable {
    case `default` = 0
    case custom = 1
    case bitcoinSegwit = 2
    case bitcoinLegacy = 3
    case bitcoinTestnet = 4
    case litecoinLegacy = 5
    case solanaSolana = 6
}
