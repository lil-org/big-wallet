// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.

#pragma once

#include "TWBase.h"
#include "TWString.h"
#include "TWData.h"

TW_EXTERN_C_BEGIN

TW_EXPORT_CLASS
struct TWWebAuthnSolidity;

/// Computes WebAuthn message hash to be signed with secp256p1 private key.
/// 
/// \param authenticator_data The authenticator data in hex format.
/// \param client_data_json The client data JSON string with a challenge.
/// \return WebAuthn message hash.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWWebAuthnSolidityGetMessageHash(TWString *_Nonnull authenticatorData, TWString *_Nonnull clientDataJson);

/// Converts the original ASN-encoded signature from webauthn to the format accepted by Barz
/// 
/// \param authenticator_data The authenticator data in hex format.
/// \param client_data_json The client data JSON string with a challenge.
/// \param der_signature original ASN-encoded signature from webauthn.
/// \return WebAuthn ABI-encoded data.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWWebAuthnSolidityGetFormattedSignature(TWString *_Nonnull authenticatorData, TWString *_Nonnull clientDataJson, TWData *_Nonnull derSignature);

TW_EXTERN_C_END
