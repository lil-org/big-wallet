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

/// Encodes `Biz.registerSession` function call to register a session passkey public key.
/// 
/// \param session_passkey_public_key The nist256p1 (aka secp256p1) public key of the session passkey.
/// \param valid_until_timestamp The timestamp until which the session is valid. Big endian uint64.
/// \return ABI-encoded function call.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBizEncodeRegisterSessionCall(struct TWPublicKey *_Nonnull sessionPasskeyPublicKey, TWData *_Nonnull validUntilTimestamp);

/// Encodes `Biz.removeSession` function call to deregister a session passkey public key.
/// 
/// \param session_passkey_public_key The nist256p1 (aka secp256p1) public key of the session passkey.
/// \return ABI-encoded function call.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBizEncodeRemoveSessionCall(struct TWPublicKey *_Nonnull sessionPasskeyPublicKey);

/// Encodes Biz Passkey Session nonce.
/// 
/// \param nonce The nonce of the Biz Passkey Session account.
/// \return uint256 represented as [passkey_nonce_key_192, nonce_64].
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBizEncodePasskeySessionNonce(TWData *_Nonnull nonce);

/// Encodes `Biz.executeWithPasskeySession` function call to execute a batch of transactions.
/// 
/// \param input The serialized data of `Biz.ExecuteWithPasskeySessionInput` protobuf message.
/// \return ABI-encoded function call.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBizEncodeExecuteWithPasskeySessionCall(TWData *_Nonnull input);

TW_EXTERN_C_END
