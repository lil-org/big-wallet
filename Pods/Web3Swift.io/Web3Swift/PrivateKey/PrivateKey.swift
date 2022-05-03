//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// PrivateKey.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** A private key */
public protocol PrivateKey: BytesScalar {

    /**
    - returns:
    address evaluated from the private key. This is not a public key

    - throws:
    `DescribedError` if something went wrong
    */
    func address() throws -> BytesScalar

}
