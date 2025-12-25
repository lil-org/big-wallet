// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.

#pragma once

#include "TWBase.h"
#include "TWPublicKey.h"
#include "TWData.h"

TW_EXTERN_C_BEGIN

TW_EXPORT_CLASS
struct TWBizPasskeySession;

/// Encodes `BizPasskeySession.registerSession` function call to register a session passkey public key.
/// 
/// \param session_passkey_public_key The nist256p1 (aka secp256p1) public key of the session passkey.
/// \param valid_until_timestamp The timestamp until which the session is valid. Big endian uint64.
/// \return ABI-encoded function call.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBizPasskeySessionEncodeRegisterSessionCall(struct TWPublicKey *_Nonnull sessionPasskeyPublicKey, TWData *_Nonnull validUntilTimestamp);

/// Encodes `BizPasskeySession.removeSession` function call to deregister a session passkey public key.
/// 
/// \param session_passkey_public_key The nist256p1 (aka secp256p1) public key of the session passkey.
/// \return ABI-encoded function call.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBizPasskeySessionEncodeRemoveSessionCall(struct TWPublicKey *_Nonnull sessionPasskeyPublicKey);

/// Encodes `BizPasskeySession` nonce.
/// 
/// \param nonce The nonce of the Biz Passkey Session account.
/// \return uint256 represented as [passkey_nonce_key_192, nonce_64].
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBizPasskeySessionEncodePasskeySessionNonce(TWData *_Nonnull nonce);

/// Encodes `BizPasskeySession.executeWithPasskeySession` function call to execute a batch of transactions.
/// 
/// \param input The serialized data of `BizPasskeySession.ExecuteWithPasskeySessionInput` protobuf message.
/// \return ABI-encoded function call.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBizPasskeySessionEncodeExecuteWithPasskeySessionCall(TWData *_Nonnull input);

/// Signs and encodes `BizPasskeySession.executeWithPasskeySession` function call to execute a batch of transactions.
/// 
/// \param input The serialized data of `BizPasskeySession.ExecuteWithSignatureInput` protobuf message.
/// \return ABI-encoded function call.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBizPasskeySessionSignExecuteWithSignatureCall(TWData *_Nonnull input);

TW_EXTERN_C_END
