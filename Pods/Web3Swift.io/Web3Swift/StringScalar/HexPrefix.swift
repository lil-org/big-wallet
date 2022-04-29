//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// HexPrefix.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Just a hex perfix */
public final class HexPrefix: StringScalar {

    /**
    - returns:
    "0x" string

    - throws:
    doesn't throw
    */
    public func value() throws -> String {
        return "0x"
    }

}
