//
// This source file is part of the 0x.swift open source project
// Copyright 2019 The 0x.swift Authors
// Licensed under Apache License v2.0
//
// EIP712Signer.swift
//
// Created by Igor Shmakov on 19/04/2019
//

import Foundation
import Web3Swift
import CryptoSwift

public final class EIP712Signer: EIP712Signable {
    
    private let privateKey: EthPrivateKey
    
    public init(privateKey: EthPrivateKey) {
        
        self.privateKey = privateKey
    }
    
    public func sign(hash: EIP712Hashable) throws -> SECP256k1Signature {
        
        let signature = SECP256k1Signature(
            digest: SimpleBytes(bytes: try hash.hash()),
            privateKey: privateKey
        )
        
        return signature
    }
}
