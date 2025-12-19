// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.

#pragma once

#include "TWBase.h"
#include "TWString.h"
#include "TWData.h"

TW_EXTERN_C_BEGIN

TW_EXPORT_CLASS
struct TWEthereum;

/// Returns the checksummed address.
/// 
/// \param address *non-null* string.
/// \return the checksummed address.
TW_EXPORT_STATIC_METHOD TWString *_Nullable TWEthereumAddressChecksummed(TWString *_Nonnull address);

/// Returns the account path from address.
/// 
/// \param eth_address *non-null* string.
/// \param layer *non-null* string.
/// \param application *non-null* string.
/// \param index *non-null* string.
/// \return the account path.
TW_EXPORT_STATIC_METHOD TWString *_Nullable TWEthereumEip2645GetPath(TWString *_Nonnull ethAddress, TWString *_Nonnull layer, TWString *_Nonnull application, TWString *_Nonnull index);

/// Returns EIP-1014 Create2 address
/// 
/// \param from *non-null* string.
/// \param salt *non-null* data.
/// \param init_code_hash *non-null* data.
/// \return the EIP-1014 Create2 address.
TW_EXPORT_STATIC_METHOD TWString *_Nullable TWEthereumEip1014Create2Address(TWString *_Nonnull from, TWData *_Nonnull salt, TWData *_Nonnull initCodeHash);

/// Returns EIP-1967 proxy init code
/// 
/// \param logic_address *non-null* string.
/// \param data *non-null* data.
/// \return the EIP-1967 proxy init code.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWEthereumEip1967ProxyInitCode(TWString *_Nonnull logicAddress, TWData *_Nonnull data);

TW_EXTERN_C_END
