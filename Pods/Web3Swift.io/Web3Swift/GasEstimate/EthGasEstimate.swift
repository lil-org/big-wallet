//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EthGasEstimate.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

public final class EthGasEstimate: BytesScalar {

    private let estimate: BytesScalar

    /**
    Ctor

    - parameters:
        - estimationProcedure: JSON of the estimate
    */
    public init(
        estimationProcedure: RemoteProcedure
    ) {
        self.estimate = EthNumber(
            hex: SimpleString{
                try estimationProcedure.call()["result"].string()
            }
        )
    }

    /**
    Ctor

    - parameters:
        - network: network to call
        - senderAddress: bytes representation of a sender address
        - recipientAddress: bytes representation of a recipient address
        - gasPrice: price that will be paid for each unit of gas
        - weiAmount: amount to be sent from sender to recipient in wei
    */
    public convenience init(
        network: Network,
        senderAddress: BytesScalar,
        gasPrice: BytesScalar,
        weiAmount: BytesScalar,
        contractCall: BytesScalar
    ) {
        self.init(
            estimationProcedure: EstimateGasProcedure(
                network: network,
                parameters: [
                    "from" : BytesParameter(
                        bytes: senderAddress
                    ),
                    "gasPrice" : QuantityParameter(
                        number: gasPrice
                    ),
                    "value" : QuantityParameter(
                        number: weiAmount
                    ),
                    "data" : BytesParameter(
                        bytes: contractCall
                    )
                ]
            )
        )
    }

    /**
    Ctor

    - parameters:
        - network: network to call
        - senderAddress: bytes representation of a sender address
        - recipientAddress: bytes representation of a recipient address
        - gasPrice: price that will be paid for each unit of gas
        - weiAmount: amount to be sent from sender to recipient in wei
    */
    public convenience init(
        network: Network,
        senderAddress: BytesScalar,
        recipientAddress: BytesScalar,
        gasPrice: BytesScalar,
        weiAmount: BytesScalar
    ) {
        self.init(
            estimationProcedure: EstimateGasProcedure(
                network: network,
                parameters: [
                    "from" : BytesParameter(
                        bytes: senderAddress
                    ),
                    "to" : BytesParameter(
                        bytes: recipientAddress
                    ),
                    "gasPrice" : QuantityParameter(
                        number: gasPrice
                    ),
                    "value" : QuantityParameter(
                        number: weiAmount
                    )
                ]
            )
        )
    }

    /**
    Ctor

    - parameters:
        - network: network to call
        - senderAddress: bytes representation of a sender address
        - recipientAddress: bytes representation of a recipient address
        - gasPrice: price that will be paid for each unit of gas
        - weiAmount: amount to be sent from sender to recipient in wei
        - contractCall: encoded contract call
    */
    public convenience init(
        network: Network,
        senderAddress: BytesScalar,
        recipientAddress: BytesScalar,
        gasPrice: BytesScalar,
        weiAmount: BytesScalar,
        contractCall: BytesScalar
    ) {
        self.init(
            estimationProcedure: EstimateGasProcedure(
                network: network,
                parameters: [
                    "from" : BytesParameter(
                        bytes: senderAddress
                    ),
                    "to" : BytesParameter(
                        bytes: recipientAddress
                    ),
                    "gasPrice" : QuantityParameter(
                        number: gasPrice
                    ),
                    "value" : QuantityParameter(
                        number: weiAmount
                    ),
                    "data" : BytesParameter(
                        bytes: contractCall
                    )
                ]
            )
        )
    }

    /**
    Ctor

    - parameters:
        - network: network to call
        - senderAddress: bytes representation of a sender address
        - gasEstimate: estimate of the gas to be spent
        - gasPrice: price that will be paid for each unit of gas
        - weiAmount: amount to be sent from sender to recipient in wei
        - contractCall: encoded contract call
    */
    public convenience init(
        network: Network,
        senderAddress: BytesScalar,
        gasEstimate: BytesScalar,
        gasPrice: BytesScalar,
        weiAmount: BytesScalar,
        contractCall: BytesScalar
    ) {
        self.init(
            estimationProcedure: EstimateGasProcedure(
                network: network,
                parameters: [
                    "from" : BytesParameter(
                        bytes: senderAddress
                    ),
                    "gas" : QuantityParameter(
                        number: gasEstimate
                    ),
                    "gasPrice" : QuantityParameter(
                        number: gasPrice
                    ),
                    "value" : QuantityParameter(
                        number: weiAmount
                    ),
                    "data" : BytesParameter(
                        bytes: contractCall
                    )
                ]
            )
        )
    }

    /**
    Ctor

    - parameters:
        - network: network to call
        - senderAddress: bytes representation of a sender address
        - recipientAddress: bytes representation of a recipient address
        - gasEstimate: estimate of the gas to be spent
        - gasPrice: price that will be paid for each unit of gas
        - weiAmount: amount to be sent from sender to recipient in wei
        - contractCall: encoded contract call
    */
    public convenience init(
        network: Network,
        senderAddress: BytesScalar,
        recipientAddress: BytesScalar,
        gasEstimate: BytesScalar,
        gasPrice: BytesScalar,
        weiAmount: BytesScalar,
        contractCall: BytesScalar
    ) {
        self.init(
            estimationProcedure: EstimateGasProcedure(
                network: network,
                parameters: [
                    "from" : BytesParameter(
                        bytes: senderAddress
                    ),
                    "to" : BytesParameter(
                        bytes: recipientAddress
                    ),
                    "gas" : QuantityParameter(
                        number: gasEstimate
                    ),
                    "gasPrice" : QuantityParameter(
                        number: gasPrice
                    ),
                    "value" : QuantityParameter(
                        number: weiAmount
                    ),
                    "data" : BytesParameter(
                        bytes: contractCall
                    )
                ]
            )
        )
    }

    /**
    - returns:
    Hexadecimal representation of an estimate value

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Data {
        return try estimate.value()
    }

}
