//
// This source file is part of the 0x.swift open source project
// Copyright 2019 The 0x.swift Authors
// Licensed under Apache License v2.0
//
// EIP712Signable.swift
//
// Created by Igor Shmakov on 19/04/2019
//

import Foundation
import Web3Swift

public protocol EIP712Signable {
    
    func sign(hash: EIP712Hashable) throws -> SECP256k1Signature
}

public extension EIP712Signable {
    
    func signatureData(hash: EIP712Hashable) throws -> Data {
        
        let signature = try sign(hash: hash)

        let message = ConcatenatedBytes(
            bytes: [
                try signature.r(),
                try signature.s(),
                SimpleBytes(bytes: [UInt8(try signature.recoverID().value() + 27)])
            ]
        )
        
        return try message.value()
    }
}
