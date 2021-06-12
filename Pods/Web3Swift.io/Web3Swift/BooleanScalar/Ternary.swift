//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// Ternary.swift
//
// Created by Timofey Solonin on 19/05/2018
//

import Foundation

/** `T` definition that is based on a boolean evaluation */
public final class Ternary<T> {

    private let `if`: BooleanScalar
    private let then: () throws -> (T)
    private let `else`: () throws -> (T)

    /**
    Ctor

    - parameters:
        - if: boolean condition for definition of `T`
        - then: closure representation of `T` associated with true
        - else: closure representation of `T` associated with false
    */
    public init(
        if: BooleanScalar,
        then: @escaping () throws -> (T),
        else: @escaping () throws -> (T)
    ) {
        self.if = `if`
        self.then = then
        self.else = `else`
    }

    /**
    Ctor

    - parameters:
        - if: boolean condition for definition of `T`
        - then: `T` associated with true
        - else: `T` associated with false
    */
    public convenience init(
        if: BooleanScalar,
        then: T,
        else: T
    ) {
        self.init(
            if: `if`,
            then: { then },
            else: { `else` }
        )
    }

    /**
    - returns:
    If `if` is true, then `then`, else `else`
    */
    public func value() throws -> T {
        if try self.if.value() {
            return try self.then()
        } else {
            return try self.else()
        }
    }

}