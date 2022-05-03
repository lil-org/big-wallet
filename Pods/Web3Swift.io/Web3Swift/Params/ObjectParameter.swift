//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ObjectParameter.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation
import SwiftyJSON

public final class ObjectParameter: EthParameter {

    private let dictionary: Dictionary<String, EthParameter>
    public init(dictionary: Dictionary<String, EthParameter>) {
        self.dictionary = dictionary
    }

    public func value() throws -> Any {
        return try dictionary.mapValues {
            try $0.value()
        }
    }

}
