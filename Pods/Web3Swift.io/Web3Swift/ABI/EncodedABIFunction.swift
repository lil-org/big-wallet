//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EncodedABIFunction.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import CryptoSwift
import Foundation

/** Encoded ABI function call */
public final class EncodedABIFunction: BytesScalar {

    private let signature: StringScalar
    private let parameters: [ABIEncodedParameter]

    //TODO: Function signature should be derived from the parameters.
    /**
    Ctor

    - parameters:
        - signature: function title followed by parameters titles
        - parameters: parameters of the function
    */
    public init(signature: StringScalar, parameters: [ABIEncodedParameter]) {
        self.signature = signature
        self.parameters = parameters
    }
    
    /**
     Ctor
     
     - parameters:
        - signature: function title followed by parameters titles
        - parameters: parameters of the function
     */
    public convenience init(signature: String, parameters: [ABIEncodedParameter]) {
        self.init(
            signature: SimpleString(
                string: signature
            ),
            parameters: parameters
        )
    }

    /**
    - returns:
    Encoded function as `Data`

    - throws:
    `DescribedError` if something went wrong.
    */
    public func value() throws -> Data {
        return try ConcatenatedBytes(
            bytes: [
                FixedLengthBytes(
                    origin: FirstBytes(
                        origin: Keccak256Bytes(
                            origin: ASCIIStringBytes(
                                string: signature
                            )
                        ),
                        length: 4
                    ),
                    length: 4
                ),
                EncodedABITuple(
                    parameters: parameters
                )
            ]
        ).value()
    }

}
