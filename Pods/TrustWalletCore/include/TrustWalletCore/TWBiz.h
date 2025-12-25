// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.

#pragma once

#include "TWBase.h"
#include "TWData.h"
#include "TWString.h"

TW_EXTERN_C_BEGIN

TW_EXPORT_CLASS
struct TWBiz;

/// Returns the encoded hash of the user operation
/// 
/// \param chain_id The chain ID of the user.
/// \param code_address The address of the smart contract wallet.
/// \param code_name The name of the smart contract wallet.
/// \param code_version The version of the smart contract wallet.
/// \param type_hash The type hash of the smart contract wallet.
/// \param domain_separator_hash The domain separator hash of the smart contract wallet.
/// \param sender The sender of the smart contract wallet.
/// \param user_op_hash The user operation hash of the smart contract wallet.
/// \return The encoded hash.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBizGetEncodedHash(TWData *_Nonnull chainId, TWString *_Nonnull codeAddress, TWString *_Nonnull codeName, TWString *_Nonnull codeVersion, TWString *_Nonnull typeHash, TWString *_Nonnull domainSeparatorHash, TWString *_Nonnull sender, TWString *_Nonnull userOpHash);

/// Signs a message using the private key
/// 
/// \param hash The hash of the user.
/// \param private_key The private key of the user.
/// \return The signed hash.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBizGetSignedHash(TWString *_Nonnull hash, TWString *_Nonnull privateKey);

/// Signs and encodes `Biz.executeWithPasskeySession` function call to execute a batch of transactions.
/// 
/// \param input The serialized data of `Biz.ExecuteWithSignatureInput` protobuf message.
/// \return ABI-encoded function call.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBizSignExecuteWithSignatureCall(TWData *_Nonnull input);

TW_EXTERN_C_END
