//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ComputedContractAddress.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Computed contract address */
public final class ComputedContractAddress: BytesScalar {

    private let address: BytesScalar

    /**
    Ctor

    - parameters:
        - ownerAddress: address of the contract deployer
        - transactionNonce: nonce that was used to deploy the contract
    */
    public init(
        ownerAddress: BytesScalar,
        transactionNonce: BytesScalar
    ) {
        self.address = EthAddress(
            bytes: LastBytes(
                origin: Keccak256Bytes(
                    origin: SimpleRLP(
                        rlps: [
                            SimpleRLP(
                                bytes: ownerAddress
                            ),
                            EthRLP(
                                number: transactionNonce
                            )
                        ]
                    )
                ),
                length: 20
            )
        )
    }

    /**
    - returns:
    Address of the contract as `Data`
    */
    public func value() throws -> Data {
        return try address.value()
    }

}
