// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE from \registry.json, changes made here WILL BE LOST.
//

#pragma once

#include "TWBase.h"

TW_EXTERN_C_BEGIN

/// Non-default coin address derivation names (default, unnamed derivations are not included).
TW_EXPORT_ENUM()
enum TWDerivation {
    TWDerivationDefault = 0, // default, for any coin
    TWDerivationCustom = 1, // custom, for any coin
    TWDerivationBitcoinSegwit = 2,
    TWDerivationBitcoinLegacy = 3,
    TWDerivationBitcoinTestnet = 4,
    TWDerivationLitecoinLegacy = 5,
    TWDerivationSolanaSolana = 6,
};

TW_EXTERN_C_END
