// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

/// HD wallet purpose
///
/// \see https://github.com/bitcoin/bips/blob/master/bip-0044.mediawiki
/// \see https://github.com/bitcoin/bips/blob/master/bip-0049.mediawiki
/// \see https://github.com/bitcoin/bips/blob/master/bip-0084.mediawiki
public enum Purpose: UInt32, CaseIterable {
    case bip44 = 44
    case bip49 = 49
    case bip84 = 84
    case bip1852 = 1852
}
