//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// CollectionScalar.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/**
    I don't think introducing type erasure is a good idea. Lets stick with
    abstract class for now but move to proper interface if they will ever
    be introduced to Swift.
*/
/** Just a collection containing values of type T. All subclasses of this abstract class must be final. */
public class CollectionScalar<T> {

    /**
    - returns:
    An `Array` representation of a collection

    - throws:
    Doesn't throw. Always errors out if super is called by the subclass.
    */
    public func value() throws -> [T] {
        fatalError("CollectionScalar is an abstract class. Implement value() method and don't call super")
    }

}
