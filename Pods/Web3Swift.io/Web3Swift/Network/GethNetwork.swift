//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// GethNetwork.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** A network of go ethereum implementation */
public final class GethNetwork: Network {
    
    private let origin: Network

    /**
    - parameters:
        - url: url for accessing JSON RPC
    */
    public init(url: String) {
        self.origin = VerifiedNetwork(
            origin: EthNetwork(
                session: URLSession(configuration: URLSessionConfiguration.default),
                url: url,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json"
                ]
            )
        )
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
