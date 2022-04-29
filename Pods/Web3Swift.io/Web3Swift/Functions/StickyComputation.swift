//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// StickyComputation.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

public final class StickyComputation<ReturnType> {

    private let computation: () throws -> (ReturnType)
    public init(computation: @escaping () throws -> (ReturnType)) {
        self.computation = computation
    }

    private var computationResult: ReturnType?
    private var error: Swift.Error?
    public func result() throws -> ReturnType {
        if let computationResult = self.computationResult {
            return computationResult
        } else if let error = self.error {
            throw error
        } else {
            let computationResult = try self.computation()
            self.computationResult = computationResult
            return computationResult
        }
    }

}
