//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// False.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Just a false boolean value */
public final class False: BooleanScalar {

    /**
    - returns:
    false `Bool`

    - throws:
    Doesn't throw
    */
    public func value() throws -> Bool {
        return false
    }

}
