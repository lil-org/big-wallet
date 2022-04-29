//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// HexPrefixedString.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** String that is prefixed by 0x */
public final class HexPrefixedString: StringScalar {

    private let origin: StringScalar

    /**
    Ctor

    - parameters:
        - origin: string to be prefixed
    */
    public init(origin: StringScalar) {
        self.origin = PrefixedString(
            origin: origin,
            prefix: HexPrefix()
        )
    }

    /**
    - returns:
    String that is prefixed by 0x

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> String {
        return try origin.value()
    }

}
