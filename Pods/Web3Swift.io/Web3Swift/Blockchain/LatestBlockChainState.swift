//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// LatestBlockChainState.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

public final class LatestBlockChainState: BlockChainState {
    
    public init() { }

    public func toString() throws -> String {
        return "latest"
    }
    
}
