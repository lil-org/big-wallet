//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// PrefixedHexString.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import CryptoSwift
import Foundation

/** Hex string that is prefixed by "0x" */
public final class PrefixedHexString: StringScalar {

    private let hex: StringScalar

    /**
    Ctor

    - parameters:
        - hex: a string describing a hexadecimal
    */
    public init(hex: StringScalar) {
        self.hex = HexPrefixedString(
            origin: HexString(
                hex: hex
            )
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
    Prefixed `String` representation of a hexadecimal

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> String {
        return try hex.value()
    }

}
