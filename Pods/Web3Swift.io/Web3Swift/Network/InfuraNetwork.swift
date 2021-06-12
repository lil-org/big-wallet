//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// InfuraNetwork.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** infura.io network */
public final class InfuraNetwork: Network {
    
    private let origin: GethNetwork

    /**
    Ctor

    - parameters:
        - chain: chain identifier
        - apiKey: api key for accessing JSON RPC calls
    */
    public init(chain: String, apiKey: String) {
        origin = GethNetwork(url: "https://"+chain+".infura.io/v3/"+apiKey)
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
        return try origin.call(method: method, params: params)
    }
    
}
