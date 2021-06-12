//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// VerifiedNetwork.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation
import SwiftyJSON

/** Network with an error verified call */
public final class VerifiedNetwork: Network {

    private let origin: Network

    /**
    Ctor

    - parameters:
        - origin: network to verify
    */
    public init(origin: Network) {
        self.origin = origin
    }

    /**
    - returns:
    id of a network

    - throws:
    `DescribedError` if something went wrong
    */
    public func id() throws -> IntegerScalar {
        return try origin.id()
    }


    /**
    - returns:
    `Data` for a JSON RPC call

    - throws:
    `DescribedError` if something went wrong
    */
    public func call(method: String, params: Array<EthParameter>) throws -> Data {
        return try VerifiedProcedure(
            origin: SimpleProcedure(
                json: JSON(
                    origin.call(
                        method: method,
                        params: params
                    )
                )
            )
        ).call().rawData()
    }

}
