//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ASCIIStringBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

internal final class NotAnASCIIScalarError: DescribedError {

    private let scalar: Unicode.Scalar
    public init(scalar: Unicode.Scalar) {
        self.scalar = scalar
    }

    internal var description: String {
        return "Scalar \(scalar.description) is not an ASCII"
    }

}

/** Bytes of the string in ascii representation */
public final class ASCIIStringBytes: BytesScalar {

    private let string: StringScalar

    /**
    - parameters:
        - string: string to be converted into bytes
    */
    public init(string: StringScalar) {
        self.string = string
    }

    /**
    - returns:
    Bytes as `Data` of the ascii representation of the string

    - throws:
    `DescribedError` if something went wrong. For instance if string consists of some elements that are not ascii.
    */
    public func value() throws -> Data {
        return try Data(
            string.value()
                .unicodeScalars
                .map{ scalar in
                    guard scalar.isASCII else {
                        throw NotAnASCIIScalarError(
                            scalar: scalar
                        )
                    }
                    return UInt8(
                        ascii: scalar
                    )
                }
        )
    }
}
