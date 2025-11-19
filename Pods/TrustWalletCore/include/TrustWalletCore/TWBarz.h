// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.

#pragma once

#include "TWBase.h"
#include "TWData.h"
#include "TWString.h"
#include "TWPublicKey.h"

TW_EXTERN_C_BEGIN

TW_EXPORT_CLASS
struct TWBarz;

/// Calculate a counterfactual address for the smart contract wallet
/// 
/// \param input The serialized data of ContractAddressInput.
/// \return The address.
TW_EXPORT_STATIC_METHOD TWString *_Nullable TWBarzGetCounterfactualAddress(TWData *_Nonnull input);

/// Returns the init code parameter of ERC-4337 User Operation
/// 
/// \param factory The address of the factory contract
/// \param public_key Public key for the verification facet
/// \param verification_facet The address of the verification facet
/// \param salt The salt of the init code; Must be non-negative
/// \return The init code.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBarzGetInitCode(TWString *_Nonnull factory, struct TWPublicKey *_Nonnull publicKey, TWString *_Nonnull verificationFacet, int32_t salt);

/// Converts the original ASN-encoded signature from webauthn to the format accepted by Barz
/// 
/// \param signature Original signature
/// \param challenge The original challenge that was signed
/// \param authenticator_data Returned from Webauthn API
/// \param client_data_json Returned from Webauthn API
/// \return Bytes of the formatted signature
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBarzGetFormattedSignature(TWData *_Nonnull signature, TWData *_Nonnull challenge, TWData *_Nonnull authenticatorData, TWString *_Nonnull clientDataJson);

/// Returns the final hash to be signed by Barz for signing messages & typed data
/// 
/// \param msg_hash Original msgHash
/// \param barzAddress The address of Barz wallet signing the message
/// \param chainId The chainId of the network the verification will happen; Must be non-negative
/// \return The final hash to be signed.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBarzGetPrefixedMsgHash(TWData *_Nonnull msgHash, TWString *_Nonnull barzAddress, int32_t chainId);

/// Returns the encoded diamondCut function call for Barz contract upgrades
/// 
/// \param input The serialized data of DiamondCutInput.
/// \return The diamond cut code.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBarzGetDiamondCutCode(TWData *_Nonnull input);

TW_EXTERN_C_END
