//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// StringScalar.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Just a string */
public protocol StringScalar {

    /**
    - returns:
    Value of the string as `String`

    - throws:
    `DescribedError` if something went wrong
    */
    func value() throws -> String

}
