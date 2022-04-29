//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EthGasPrice.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Gas price computed by the network */
public final class EthGasPrice: BytesScalar {

    private let price: BytesScalar

    /**
    Ctor

    - parameters:
        - network: network to ask for gas price
    */
    public init(network: Network) {
        self.price = EthNumber(
            hex: SimpleString{
                try GetGasPriceProcedure(
                    network: network
                ).call()["result"].string()
            }
        )
    }

    /**
    - returns:
    Compact hex representation of a gas price

    - throws:
    `DescribedError` if something goes wrong
    */
    public func value() throws -> Data {
        return try price.value()
    }

}
