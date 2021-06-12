//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// BytesScalar.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Just some bytes */
public protocol BytesScalar {

    /**
    - returns:
    bytes represented as `Data`
    */
    func value() throws -> Data

}
