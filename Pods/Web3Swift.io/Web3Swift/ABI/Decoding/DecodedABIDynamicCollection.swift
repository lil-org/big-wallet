//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// DecodedABIDynamicCollection.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Decoded typed abi collection */
public final class DecodedABIDynamicCollection<T>: CollectionScalar<T> {

    private let abiMessage: CollectionScalar<BytesScalar>
    private let mapping: (
        (
            slice: CollectionScalar<BytesScalar>,
            index: Int
        )
    ) throws -> (T)
    private let index: Int

    /**
    Ctor
    
    - parameters:
        - abiMessage: message where dynamic collection is located
        - mapping: transformation for elements of the collection
        - index: position of the collection
    */
    public init(
        abiMessage: CollectionScalar<BytesScalar>,
        mapping: @escaping (
            (
                slice: CollectionScalar<BytesScalar>,
                index: Int
            )
        ) throws -> (T),
        index: Int
    ) {
        self.abiMessage = abiMessage
        self.mapping = mapping
        self.index = index
    }

    /**
    - returns:
    A collection of elements specified by the `mapping`
    
    - throws:
    `DescribedError` if something went wrong
    */
    public override func value() throws -> [T] {
        let mapping = self.mapping
        let elementsCount: Int = try EthInteger(
            hex: BytesAt(
                collection: abiMessage,
                index: IntegersQuotient(
                    dividend: EthInteger(
                        hex: BytesAt(
                            collection: abiMessage,
                            index: index
                        )
                    ),
                    divisor: SimpleInteger(
                        integer: 32
                    )
                )
            )
        ).value()
        let slice = ABICollectionSlice(
            abiMessage: abiMessage,
            index: index
        )
        return try GeneratedCollection(
            element: { index in
                try mapping(
                    (
                        slice: slice,
                        index: index
                    )
                )
            },
            times: elementsCount
        ).value()
    }

}
