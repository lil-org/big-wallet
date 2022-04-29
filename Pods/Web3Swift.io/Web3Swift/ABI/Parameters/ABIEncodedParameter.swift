//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ABIEncodedParameter.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** An encoded ABI parameter */
public protocol ABIEncodedParameter {

    /**
    - parameters:
        - offset: number of elements preceding the parameter tails

    - returns:
    A collection of 32 bytes pieces of the head of the encoded parameter.

    - throws:
    `DescribedError` if something went wrong
    */
    func heads(offset: Int) throws -> [BytesScalar]

    /**
    - parameters:
        - offset: number of elements preceding the parameter tails

    - returns:
    A collection of 32 bytes pieces of the tail of the encoded parameter. Tail is empty for "static" parameters.

    - throws:
    `DescribedError` if something went wrong
    */
    func tails(offset: Int) throws -> [BytesScalar]
    
    /**
    - returns:
    True if parameter is dynamic according to the ABI specification. False otherwise.
    */
    func isDynamic() -> Bool
    
    /**
    - returns:
    A count of heads elements of the parameter
    */
    func headsCount() -> Int

}
