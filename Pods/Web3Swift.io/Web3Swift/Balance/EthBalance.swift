//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EthBalance.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Balance of an address */
public final class EthBalance: BytesScalar {

    private let origin: BytesScalar

    /**
    Ctor

    - parameters:
        - network: network to ask for balance
        - address: address of the balance
    */
    public init(
        network: Network,
        address: BytesScalar
    ) {
        self.origin = EthNumber(
            hex: SimpleString{
                try BalanceProcedure(
                    network: network,
                    address: address,
                    state: PendingBlockChainState()
                ).call()["result"].string()
            }
        )
    }

    /**
    - returns:
    Balance in hex

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Data {
        return try origin.value()
    }

}
