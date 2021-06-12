//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ECRecoverableSignature.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Elliptic curve recoverable signature */
public protocol ECRecoverableSignature {

    /**
        R value as defined in ecdsa

        - returns:
        bytes representation

        - throws:
        `DescribedError` if something went wrong
    */
    func r() throws -> BytesScalar

    /**
        S value as defined in ecdsa

        - returns:
        bytes representation

        - throws:
        `DescribedError` if something went wrong
    */
    func s() throws -> BytesScalar

    /**
        Recovery id as defined in ecdsa

        - returns:
        a number

        - throws:
        `DescribedError` if something went wrong
    */
    func recoverID() throws -> IntegerScalar

}
