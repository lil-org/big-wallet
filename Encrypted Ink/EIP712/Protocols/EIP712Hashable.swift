//
// This source file is part of the 0x.swift open source project
// Copyright 2019 The 0x.swift Authors
// Licensed under Apache License v2.0
//
// EIP712Hashable.swift
//
// Created by Igor Shmakov on 17/04/2019
//

import Foundation

public protocol EIP712Hashable {
    
    func hash() throws -> Data
}
