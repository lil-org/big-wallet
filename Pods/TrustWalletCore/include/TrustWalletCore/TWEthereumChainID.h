// Copyright © 2017-2022 Trust Wallet.
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

/// Chain identifiers for Ethereum-based blockchains, for convenience. Recommended to use the dynamic CoinType.ChainId() instead.
/// See also TWChainId.
TW_EXPORT_ENUM(uint32_t)
enum TWEthereumChainID {
    TWEthereumChainIDEthereum = 1,
    TWEthereumChainIDClassic = 61,
    TWEthereumChainIDPoa = 99,
    TWEthereumChainIDVechain = 74,
    TWEthereumChainIDCallisto = 820,
    TWEthereumChainIDTomochain = 88,
    TWEthereumChainIDPolygon = 137,
    TWEthereumChainIDOkc = 66,
    TWEthereumChainIDThundertoken = 108,
    TWEthereumChainIDGochain = 60,
    TWEthereumChainIDMeter = 82,
    TWEthereumChainIDCelo = 42220,
    TWEthereumChainIDWanchain = 888,
    TWEthereumChainIDCronos = 25,
    TWEthereumChainIDOptimism = 10,
    TWEthereumChainIDXdai = 100,
    TWEthereumChainIDSmartbch = 10000,
    TWEthereumChainIDFantom = 250,
    TWEthereumChainIDBoba = 288,
    TWEthereumChainIDKcc = 321,
    TWEthereumChainIDHeco = 128,
    TWEthereumChainIDMetis = 1088,
    TWEthereumChainIDMoonbeam = 1284,
    TWEthereumChainIDMoonriver = 1285,
    TWEthereumChainIDRonin = 2020,
    TWEthereumChainIDKavaevm = 2222,
    TWEthereumChainIDKlaytn = 8217,
    TWEthereumChainIDAvalanchec = 43114,
    TWEthereumChainIDEvmos = 9001,
    TWEthereumChainIDArbitrum = 42161,
    TWEthereumChainIDSmartchain = 56,
    TWEthereumChainIDAurora = 1313161554,
};

TW_EXTERN_C_END
