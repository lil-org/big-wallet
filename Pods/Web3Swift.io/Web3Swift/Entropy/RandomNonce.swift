//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// RandomNonce.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation
import Security

public final class SecRandomError: Swift.Error { }

public final class RandomNonce: Entropy {

    private let size: Int

    public init(size: Int) {
        self.size = Int(size)
    }

    private var cachedNonce: Data?

    public func toData() throws -> Data {
        if let nonce = cachedNonce {
            return nonce
        } else {
            var randomBytes = Array<UInt8>(repeating: 0, count: size)
            if SecRandomCopyBytes(kSecRandomDefault, size, &randomBytes) == errSecSuccess {
                let nonce = Data(randomBytes)
                cachedNonce = nonce
                return nonce
            } else {
                throw SecRandomError()
            }
        }
    }

}
