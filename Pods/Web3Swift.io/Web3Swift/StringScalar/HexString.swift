//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// HexString.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import CryptoSwift
import Foundation

internal final class AmbiguousHexStringError: DescribedError {

    private let hex: String
    public init(hex: String) {
        self.hex = hex
    }

    internal var description: String {
        return "Hex string \(hex) length \(hex.count) is not even"
    }

}

internal final class IncorrectHexCharacterError: DescribedError {

    private let hex: String

    public init(hex: String) {
        self.hex = hex
    }

    public var description: String {
        //TODO: Highlight incorrect characters here
        return "Incorrect hex string \"\(self.hex)\""
    }

}

/** A string that represents some collection of hexadecimal numbers */
public final class HexString: StringScalar {

    private let hex: StringScalar

    /**
    Ctor

    - parameters:
        - hex: a string describing a hexadecimal
    */
    public init(hex: StringScalar) {
        self.hex = hex
    }

    /**
    Ctor

    - parameters:
        - hex: a string describing a hexadecimal
    */
    public convenience init(hex: String) {
        self.init(
            hex: SimpleString(
                string: hex
            )
        )
    }

    /**
    TODO: Validations below are temporarily coupled. single() call will cause valid hex strings such as "0x" or "" to be denied but it will not trigger because swift will verify only first two cases. This is a bad design. (sequential search)

    - returns:
    `String` representation of a string describing a hexadecimal

    - throws:
    `DescribedError` if something went wrong or if string does not describe a hexadecimal or hexadecimal description is ambiguous
    */
    public func value() throws -> String {
        let hex = try self.hex.value()
        guard try hex.isEmpty || hex == HexPrefix().value() || NSRegularExpression(pattern: "(0[xX]){0,1}[0-9a-fA-F]+").matches(
            in: hex,
            range: NSRange(location: 0, length: hex.count)
        ).first?.range == NSRange(location: 0, length: hex.count) else {
            throw IncorrectHexCharacterError(hex: hex)
        }
        guard hex.count.isEven() else {
            throw AmbiguousHexStringError(hex: hex)
        }
        return hex
    }

}
