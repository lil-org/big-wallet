//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EthParameter.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Parameter to be passed to the network */
public protocol EthParameter {

    /**
    - returns:
    one of the types accepted by default swift encoder. Unfortunately they do not share any interface for the purpose of encoding and have to passed as `Any`.

    - throws:
    `DescribedError` is something went wrong
    */
    func value() throws -> Any

}
