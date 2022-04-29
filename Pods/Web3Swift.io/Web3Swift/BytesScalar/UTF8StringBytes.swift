//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// UTF8StringBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Bytes of the string in UTF8 representation */
public final class UTF8StringBytes: BytesScalar {

    private let string: StringScalar

    /**
    Ctor

    - parameters:
        - string: string to be evaluated for bytes
    */
    public init(string: StringScalar) {
        self.string = string
    }

    /**
    Ctor

    - parameters:
        - string: string to be evaluated for bytes
    */
    public convenience init(string: String) {
        self.init(
            string: SimpleString{ string }
        )
    }

    /**
    - returns:
    bytes as `Data` of the string interpreted as utf8 bytes collection

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Data {
        return try Data(
            Array(
                string.value().utf8
            )
        )
    }

}
