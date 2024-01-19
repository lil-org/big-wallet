// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

/// Public key types
public enum PublicKeyType: UInt32, CaseIterable {
    case secp256k1 = 0
    case secp256k1Extended = 1
    case nist256p1 = 2
    case nist256p1Extended = 3
    case ed25519 = 4
    case ed25519Blake2b = 5
    case curve25519 = 6
    case ed25519Cardano = 7
    case starkex = 8
}
