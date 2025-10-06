// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.

#pragma once

#include "TWBase.h"
#include "TWData.h"
#include "TWString.h"

TW_EXTERN_C_BEGIN

TW_EXPORT_CLASS
struct TWEip7702;

/// Signs an Authorization hash in [EIP-7702 format](https://eips.ethereum.org/EIPS/eip-7702)
/// 
/// \param chain_id The chain ID of the user.
/// \param contract_address The address of the smart contract wallet.
/// \param nonce The nonce of the user.
/// \param private_key The private key of the user.
/// \return The signed authorization.
TW_EXPORT_STATIC_METHOD TWString *_Nullable TWEip7702SignAuthorization(TWData *_Nonnull chainId, TWString *_Nonnull contractAddress, TWData *_Nonnull nonce, TWString *_Nonnull privateKey);

/// Computes an Authorization hash in [EIP-7702 format](https://eips.ethereum.org/EIPS/eip-7702)
/// `keccak256('0x05' || rlp([chain_id, address, nonce]))`.
/// 
/// \param chain_id The chain ID of the user.
/// \param contract_address The address of the smart contract wallet.
/// \param nonce The nonce of the user.
/// \return The authorization hash.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWEip7702GetAuthorizationHash(TWData *_Nonnull chainId, TWString *_Nonnull contractAddress, TWData *_Nonnull nonce);

TW_EXTERN_C_END
