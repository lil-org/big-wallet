//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// SimpleNetwork.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Anonymous network */
public final class SimpleNetwork: Network {

    private let identifier: () throws -> (IntegerScalar)
    private let response: (String, [EthParameter]) throws -> (Data)

    /**
    Ctor

    - parameters:
        - id: closure representation of the id of the network
        - call: closure representation of the call response
    */
    public init(
        id: @escaping () throws -> (IntegerScalar),
        call: @escaping (String, [EthParameter]) throws -> (Data)
    ) {
        self.identifier = id
        self.response = call
    }

    /**
    - returns:
    id of the network

    - throws:
    `DescribedError` if something went wrong
    */
    public func id() throws -> IntegerScalar {
        return try self.identifier()
    }

    /**
    - returns:
    `Data` for a JSON RPC call

    - throws:
    `DescribedError` if something went wrong
    */
    public func call(method: String, params: Array<EthParameter>) throws -> Data {
        return try self.response(
            method,
            params
        )
    }

}
