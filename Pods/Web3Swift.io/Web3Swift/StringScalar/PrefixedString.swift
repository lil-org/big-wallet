//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// PrefixedString.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** String that is prefixed */
public final class PrefixedString: StringScalar {

    private let origin: StringScalar
    private let prefix: StringScalar

    /**
    Ctor

    - parameters:
        - origin: origin to be prefixed
        - prefix: prefix to persist
    */
    public init(
        origin: StringScalar,
        prefix: StringScalar
    ) {
        self.origin = origin
        self.prefix = prefix
    }

    /**
    - returns:
    `String` that is prefixed by the specified prefix if one doesn't exist

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> String {
        let origin = try self.origin.value()
        let prefix = try self.prefix.value()
        if origin.hasPrefix(prefix) {
            return origin
        } else {
            return "\(prefix)\(origin)"
        }
    }

}
