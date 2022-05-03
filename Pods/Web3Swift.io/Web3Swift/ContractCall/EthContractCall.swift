//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EthContractCall.swift
//
// Created by Timofey Solonin on 25/05/2018
//

import Foundation

/**
    Contract call response that is simulated on the node. This call doesn't
    change any state in the network.
*/
public final class EthContractCall: BytesScalar {

    private let call: BytesScalar

    /**
    Ctor

    - parameters:
        - call: json representation of contract call
    */
    public init(
        call: RemoteProcedure
    ) {
        self.call = BytesFromHexString(
            hex: JSONResultString(
                json: call
            )
        )
    }

    /**
    Ctor

    - parameters:
        - network: network to call
        - contractAddress: address of the contract
        - functionCall: encoded call the contract function
    */
    public convenience init(
        network: Network,
        contractAddress: BytesScalar,
        functionCall: BytesScalar
    ) {
        self.init(
            call: ContractCallProcedure(
                network: network,
                parameters: [
                    "to" : BytesParameter(
                        bytes: contractAddress
                    ),
                    "data" : BytesParameter(
                        bytes: functionCall
                    )
                ]
            )
        )
    }

    /**
    Ctor

    - parameters:
        - network: network to call
        - senderAddress: address of the msg.sender
        - contractAddress: address of the contract
        - functionCall: encoded call the contract function
    */
    public convenience init(
        network: Network,
        senderAddress: BytesScalar,
        contractAddress: BytesScalar,
        functionCall: BytesScalar
    ) {
        self.init(
            call: ContractCallProcedure(
                network: network,
                parameters: [
                    "from" : BytesParameter(
                        bytes: senderAddress
                    ),
                    "to" : BytesParameter(
                        bytes: contractAddress
                    ),
                    "data" : BytesParameter(
                        bytes: functionCall
                    )
                ]
            )
        )
    }

    /**
    Ctor

    - parameters:
        - network: network to call
        - senderAddress: address of the msg.sender
        - contractAddress: address of the contract
        - weiAmount: amount to be sent in wei
        - functionCall: encoded call the contract function
    */
    public convenience init(
        network: Network,
        senderAddress: BytesScalar,
        contractAddress: BytesScalar,
        weiAmount: BytesScalar,
        functionCall: BytesScalar
    ) {
        self.init(
            call: ContractCallProcedure(
                network: network,
                parameters: [
                    "from" : BytesParameter(
                        bytes: senderAddress
                    ),
                    "to" : BytesParameter(
                        bytes: contractAddress
                    ),
                    "value" : QuantityParameter(
                        number: weiAmount
                    ),
                    "data" : BytesParameter(
                        bytes: functionCall
                    )
                ]
            )
        )
    }

    /**
    - returns:
    The return of the function call
    */
    public func value() throws -> Data {
        return try call.value()
    }

}
