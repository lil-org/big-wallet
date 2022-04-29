//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// Network.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

public protocol Network {

    /**
    - returns:
    id of a network

    - throws:
    `DescribedError` if something went wrong
    */
    func id() throws -> IntegerScalar

    /**
    - returns:
    `Data` for a JSON RPC call

    - throws:
    `DescribedError` if something went wrong
    */
    func call(method: String, params: Array<EthParameter>) throws -> Data

}
