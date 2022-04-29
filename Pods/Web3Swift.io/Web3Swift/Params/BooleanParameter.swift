//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// BooleanParameter.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

public final class BooleanParameter: EthParameter {
    
    private var param: Bool
    
    public init(value: Bool) {
        self.param = value
    }

    public func value() throws -> Any {
        return param
    }
    
}
