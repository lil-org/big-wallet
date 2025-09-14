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
/// \param factory The address of the factory contract.
/// \param public_key Public key for the verification facet
/// \param verification_facet The address of the verification facet.
/// \param salt The salt of the init code.
/// \return The init code.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBarzGetInitCode(TWString *_Nonnull factory, struct TWPublicKey *_Nonnull publicKey, TWString *_Nonnull verificationFacet, uint32_t salt);

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
/// \param chainId The chainId of the network the verification will happen
/// \return The final hash to be signed.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBarzGetPrefixedMsgHash(TWData *_Nonnull msgHash, TWString *_Nonnull barzAddress, uint32_t chainId);

/// Returns the encoded diamondCut function call for Barz contract upgrades
/// 
/// \param input The serialized data of DiamondCutInput.
/// \return The diamond cut code.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBarzGetDiamondCutCode(TWData *_Nonnull input);

/// Computes an Authorization hash in [EIP-7702 format](https://eips.ethereum.org/EIPS/eip-7702)
/// `keccak256('0x05' || rlp([chain_id, address, nonce]))`.
/// 
/// \param chain_id The chain ID of the user.
/// \param contract_address The address of the smart contract wallet.
/// \param nonce The nonce of the user.
/// \return The authorization hash.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBarzGetAuthorizationHash(TWData *_Nonnull chainId, TWString *_Nonnull contractAddress, TWData *_Nonnull nonce);

/// Returns the signed authorization hash
/// 
/// \param chain_id The chain ID of the user.
/// \param contract_address The address of the smart contract wallet.
/// \param nonce The nonce of the user.
/// \param private_key The private key of the user.
/// \return The signed authorization.
TW_EXPORT_STATIC_METHOD TWString *_Nullable TWBarzSignAuthorization(TWData *_Nonnull chainId, TWString *_Nonnull contractAddress, TWData *_Nonnull nonce, TWString *_Nonnull privateKey);

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
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBarzGetEncodedHash(TWData *_Nonnull chainId, TWString *_Nonnull codeAddress, TWString *_Nonnull codeName, TWString *_Nonnull codeVersion, TWString *_Nonnull typeHash, TWString *_Nonnull domainSeparatorHash, TWString *_Nonnull sender, TWString *_Nonnull userOpHash);

/// Signs a message using the private key
/// 
/// \param hash The hash of the user.
/// \param private_key The private key of the user.
/// \return The signed hash.
TW_EXPORT_STATIC_METHOD TWData *_Nullable TWBarzGetSignedHash(TWString *_Nonnull hash, TWString *_Nonnull privateKey);

TW_EXTERN_C_END
