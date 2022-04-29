//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// TagParameter.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

public final class TagParameter: EthParameter {
    
    private var state: BlockChainState
    
    public init(state: BlockChainState) {
        self.state = state
    }

    public func value() throws -> Any {
        return try state.toString()
    }
    
}
