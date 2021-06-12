//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// BooleanScalar.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Just a Bool */
public protocol BooleanScalar {

    /**
    - returns:
    Value of a boolean as `Bool`

    - throws:
    `DescribedError` if something went wrong
    */
    func value() throws -> Bool

}
