//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// BytesFromHexString.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import CryptoSwift
import Foundation

/** Bytes from their string representation. The string representation of bytes must not be ambiguous. */
public final class BytesFromHexString: BytesScalar {

    private let hex: StringScalar

    /**
    Ctor

    - parameters:
        - hex: `StringScalar` representing bytes in hex format
    */
    public init(hex: StringScalar) {
        self.hex = HexString(hex: hex)
    }

    /**
    Ctor

    - parameters:
        - hex: `String` representing bytes in hex format
    */
    public convenience init(hex: String) {
        self.init(
            hex: SimpleString(
                string: hex
            )
        )
    }

    /**
    - returns:
    Bytes interpretation of the content of the string

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Data {
        return try Data(
            hex: hex.value()
        )
    }

}
