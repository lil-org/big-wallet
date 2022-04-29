//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EstimateGasProcedure.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation
import SwiftyJSON

public final class EstimateGasProcedure: RemoteProcedure {

    private let network: Network
    private let parameters: [String: EthParameter]

    /**
    Ctor

    - parameters:
        - network: network to call
        - parameters: arguments of the estimate
    */
    public init(
        network: Network,
        parameters: [String: EthParameter]
    ) {
        self.network = network
        self.parameters = parameters
    }


    /**
    - returns:
    `JSON` for the gas estimate

    - throws:
    `DescribedError` if something went wrong
    */
    public func call() throws -> JSON {
        return try JSON(
            data: network.call(
                method: "eth_estimateGas",
                params: [
                    ObjectParameter(
                        dictionary: parameters
                    )
                ]
            )
        )
    }

}
