//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// UnprefixedHexString.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Hex string that is not prefixed by "0x" */
public final class UnprefixedHexString: StringScalar {

    private let hex: StringScalar

    /**
    Ctor

    - parameters:
        - hex: a string describing a hexadecimal
    */
    public init(hex: StringScalar) {
        self.hex = TrimmedPrefixString(
            string: HexString(hex: hex),
            prefix: HexPrefix()
        )
    }

    /**
    Ctor

    - parameters:
        - bytes: bytes of a hexadecimal
    */
    public convenience init(bytes: BytesScalar) {
        self.init(
            hex: SimpleString{
                try bytes.value().toHexString()
            }
        )
    }

    /**
    - returns:
    Unprefixed `String` representation of a hexadecimal

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> String {
        return try hex.value()
    }

}
