//
// This source file is part of the Web3Swift.io open source project
// Copyright 2019 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// DecimalScalar.swift
//
// Created by Vadim Koleoshkin on 09/05/2019
//

import Foundation

/** Just a Decimal number */
public protocol DecimalScalar {
    
    /**
     - returns:
     bytes represented as `Decimal`
     */
    func value() throws -> Decimal
    
}
