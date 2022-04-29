//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EthPrivateKey.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import CryptoSwift
import Foundation
import secp256k1

private final class InvalidPrivateKeyError: DescribedError {

    internal var description: String {
        return "Private key was incorrect"
    }

}

private final class PublicKeySerializationError: DescribedError {

    internal var description: String {
        return "Could not serialize public key for unknown reason"
    }

}

/** Private key as specified in the ethereum */
public final class EthPrivateKey: PrivateKey {

    private let bytes: BytesScalar

    /**
    Ctor

    - parameters:
        - bytes: 32 bytes representation of the private key
    */
    public init(bytes: BytesScalar) {
        self.bytes = FixedLengthBytes(
            origin: bytes,
            length: 32
        )
    }
    
    /**
     Ctor
     
     - parameters:
        - hex: `StringScalar` representing bytes of the address in hex format
     */
    public convenience init(hex: StringScalar) {
        self.init(
            bytes: BytesFromHexString(
                hex: hex
            )
        )
    }
    
    /**
     Ctor
     
     - parameters:
        - hex: `String` representing bytes of the address in hex format
     */
    public convenience init(hex: String) {
        self.init(
            hex: SimpleString{
                hex
            }
        )
    }

    /**
    - returns:
    32 bytes as `Data` of the private key

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Data {
        return try bytes.value()
    }

    /**
    TODO: This method should be decomposed into multiple instances to make computations such as dropping header byte more declarative.

    - returns:
    64 bytes public key computed from the private key
    */
    private func publicKey() -> BytesScalar {
        let bytes = self.bytes
        return SimpleBytes{
            var publicKeyStructure = secp256k1_pubkey()
            var privateKey = try Array<UInt8>(bytes.value())
            guard secp256k1_ec_pubkey_create(
                secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN) | UInt32(SECP256K1_CONTEXT_VERIFY)),
                &publicKeyStructure,
                &privateKey
            ) == 1 else {
                throw InvalidPrivateKeyError()
            }
            var publicKey = Array<UInt8>(repeating: 0x00, count: 65)
            var outputLength = Int(65)
            guard secp256k1_ec_pubkey_serialize(
                secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN) | UInt32(SECP256K1_CONTEXT_VERIFY)),
                &publicKey,
                &outputLength,
                &publicKeyStructure,
                UInt32(SECP256K1_EC_UNCOMPRESSED)
            ) == 1 else {
                throw PublicKeySerializationError()
            }
            return Data(
                publicKey.dropFirst()
            )
        }
    }

    /**
    TODO: This method should be decomposed into an Address object

    - returns:
    20 bytes address computed from the private key as specified by the ethereum

    - throws:
    doesn't throw
    */
    public func address() throws -> BytesScalar {
        let publicKey = self.publicKey()
        return LastBytes(
            origin: Keccak256Bytes(
                origin: SimpleBytes{
                    try publicKey.value()
                }
            ),
            length: 20
        )
    }

}
