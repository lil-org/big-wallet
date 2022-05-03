//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// SECP256k1Signature.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import CryptoSwift
import Foundation
import secp256k1

public final class SigningError: DescribedError {

    private let hash: Array<UInt8>
    public init(hash: Array<UInt8>) {
        self.hash = hash
    }

    public var description: String {
        return "Libsecp256k1 failed raw signature for hash \(self.hash.toHexString())"
    }

}

public final class SignatureSerializationError: DescribedError {

    private let rs: Array<UInt8>
    private let recoveryID: Int32
    private let signature: secp256k1_ecdsa_recoverable_signature
    public init(
        rs: Array<UInt8>,
        recoveryID: Int32,
        signature: secp256k1_ecdsa_recoverable_signature
    ) {
        self.rs = rs
        self.recoveryID = recoveryID
        self.signature = signature
    }

    public var description: String {
        var tmp = signature.data
        let signatureHex: String = Array<UInt8>(
            UnsafeBufferPointer(
                start: &tmp.0,
                count: MemoryLayout.size(ofValue: tmp)
            )
        ).toHexString()
        return "Libsecp256k1 failed to serialize for raw signature\n" +
            "Raw signature hex: \(signatureHex)\n" +
            "RS value: \(self.rs.toHexString())\n" +
            "Recovery id: \(self.recoveryID)"
    }

}

/** / This is an object that represents EC recoverable signature for EC secp256k1. */
public final class SECP256k1Signature: ECRecoverableSignature {

    // swiftlint:disable:next large_tuple
    private let stickyComputation: StickyComputation<(r: Data, s: Data, recoveryID: UInt8)>

    /**
    Ctor

    - parameters:
        - digest: 32 bytes digest of the message to sign
        - privateKey: value of the private key
    */
    public init(
        digest: BytesScalar,
        privateKey: BytesScalar
    ) {
        let digest = FixedLengthBytes(
            origin: digest,
            length: 32
        )
        stickyComputation = StickyComputation{
            var digest = try Array(digest.value())
            var signature: secp256k1_ecdsa_recoverable_signature = secp256k1_ecdsa_recoverable_signature()
            var privateKey = try Array(privateKey.value())
            guard secp256k1_ecdsa_sign_recoverable(
                secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN | SECP256K1_CONTEXT_VERIFY)),
                &signature,
                &digest,
                &privateKey,
                nil,
                nil
            ) == 1 else {
                throw SigningError(hash: digest)
            }
            var rs: Array<UInt8> = Array<UInt8>(repeating: 0, count: 64)
            var recoveryID: Int32 = -1
            guard secp256k1_ecdsa_recoverable_signature_serialize_compact(
                secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN | SECP256K1_CONTEXT_VERIFY)),
                &rs,
                &recoveryID,
                &signature
            ) == 1 && (0...255).contains(recoveryID) else {
                throw SignatureSerializationError(
                    rs: rs,
                    recoveryID: recoveryID,
                    signature: signature
                )
            }
            return (
                r: Data(rs.prefix(32)),
                s: Data(rs.suffix(32)),
                recoveryID: UInt8(recoveryID)
            )
        }
    }

    /**
        ctor

        - parameters:
            - privateKey: private key as defined in ecdsa
            - message: message as fined in ecdsa
            - hashFunction: hashing function that is used to compute message hash
    */
    public convenience init(
        privateKey: PrivateKey,
        message: BytesScalar,
        hashFunction: @escaping (Array<UInt8>) -> (Array<UInt8>)
    ) {
        self.init(
            digest: SimpleBytes{
                try Data(
                    hashFunction(
                        Array<UInt8>(
                            message.value()
                        )
                    )
                )
            },
            privateKey: privateKey
        )
    }

    /**
        R point as defined in ecdsa

        - returns:
        32 byte `Data`

        - throws:
        `DescribedError` if something went wrong
    */
    public func r() throws -> BytesScalar {
        let stickyComputation = self.stickyComputation
        return EthNumber(
            hex: SimpleBytes{
                try stickyComputation.result().r
            }
        )
    }

    /**
        S point as defined in ecdsa

        - returns:
        32 byte `Data`

        - throws:
        `DescribedError` if something went wrong
    */
    public func s() throws -> BytesScalar {
        let stickyComputation = self.stickyComputation
        return EthNumber(
            hex: SimpleBytes{
                try stickyComputation.result().s
            }
        )
    }

    //TODO: This need to be properly wrapped
    /**
        Recovery id as defined in ecdsa

        - returns:
        a single byte from 0 to 3

        - throws:
        `DescribedError` if something went wrong
    */
    public func recoverID() throws -> IntegerScalar {
        let stickyComputation = self.stickyComputation
        return SimpleInteger{
            Int(
                try stickyComputation.result().recoveryID
            )
        }
    }

}
