//
// This source file is part of the Web3Swift.io open source project
// Copyright 2019 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// SignedPersonalMessageBytes.swift
//
// Created by Vadim Koleoshkin on 10/05/2019
//

import CryptoSwift
import Foundation

/** Bytes representing Ethereum personal message */
public final class SignedPersonalMessageBytes: BytesScalar {
    
    private let message: StringScalar
    private let signerKey: PrivateKey
    
    /**
     Ctor
     
     - parameters:
        - message: input message.
     */
    public init(message: StringScalar, signerKey: PrivateKey) {
        self.message = message
        self.signerKey = signerKey
    }
    
    /**
     Ctor
     
     - parameters:
        - message: string input message.
     */
    public convenience init(message: String, signerKey: PrivateKey) {
        self.init(
            message: SimpleString(
                string: message
            ),
            signerKey: signerKey
        )
    }
    
    public func value() throws -> Data {
        let signature = SECP256k1Signature(
            privateKey: signerKey,
            message: PersonalMessageBytes(
                message: message
            ),
            hashFunction: SHA3(variant: .keccak256).calculate
        )
        return try ConcatenatedBytes(
            bytes: [
                signature.r(),
                signature.s(),
                EthNumber(value: signature.recoverID().value() + 27)
            ]
        ).value()
    }
}
