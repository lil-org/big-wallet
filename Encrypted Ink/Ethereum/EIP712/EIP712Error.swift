//
// This source file is part of the 0x.swift open source project
// Copyright 2019 The 0x.swift Authors
// Licensed under Apache License v2.0
//
// EIP712Error.swift
//
// Created by Igor Shmakov on 09/04/2019
//

import Foundation

public enum EIP712Error: Error {
    
    case notImplemented
    case invalidInput
    case invalidMessage
    case invalidParameter(name: String)
    case invalidType(name: String)
    
    case invalidTypedData
    case invalidTypedDataPrimaryType
    case invalidTypedDataDomain
    case invalidTypedDataMessage
    case invalidTypedDataType
    case invalidTypedDataValue
    case integerOverflow
    
    case signatureVerificationError
}
