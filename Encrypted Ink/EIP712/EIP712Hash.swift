//
// This source file is part of the 0x.swift open source project
// Copyright 2019 The 0x.swift Authors
// Licensed under Apache License v2.0
//
// Hash:.swift
//
// Created by Igor Shmakov on 09/04/2019
//

import Foundation

public class EIP712Hash: EIP712Hashable {
    
    private let typedData: EIP712Hashable
    private let domain: EIP712Hashable
    
    public init(domain: EIP712Hashable, typedData: EIP712Hashable) {
        
        self.domain = domain
        self.typedData = typedData
    }

    public func hash() throws -> Data {
        guard
            let domainData = try? domain.hash(),
            let structData = try? typedData.hash()
        else {
            throw EIP712Error.invalidMessage
        }
        return (Data(hex: "0x1901") + domainData + structData).sha3(.keccak256)
    }
}
