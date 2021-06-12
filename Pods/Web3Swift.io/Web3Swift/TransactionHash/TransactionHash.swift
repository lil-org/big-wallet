//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// TransactionHash.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Hash of a raw transaction data */
public protocol TransactionHash: BytesScalar {

    /**
    - returns:
    `Transaction` that is associated with the hash

    - throws:
    `DescribedError if something went wrong`
    */
    func transaction() throws -> Transaction

    /**
    - returns:
    `TransactionReceipt` that is associated with the hash

    - throws:
    `DescribedError if something went wrong`
    */
    func receipt() throws -> TransactionReceipt

}
