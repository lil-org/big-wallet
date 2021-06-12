//
// This source file is part of the 0x.swift open source project
// Copyright 2019 The 0x.swift Authors
// Licensed under Apache License v2.0
//
// EIP712Type.swift
//
// Created by Igor Shmakov on 15/04/2019
//

import Foundation

public struct EIP712Type {
    
    public let name: String
    public let parameters: [EIP712Parameter]
    
    public func encode() -> String {
        let encodedParameters = parameters.map { $0.encode() }.joined(separator: ",")
        return "\(name)(\(encodedParameters))"
    }
}
