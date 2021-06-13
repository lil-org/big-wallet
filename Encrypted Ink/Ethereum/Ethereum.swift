// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation
import Web3Swift
import CryptoSwift

struct Transaction {
    let transactionsCount: String?
    let gasPrice: String?
    let gasEstimate: String?
    let recipientAddress: String
    let weiAmount: String
    let contractCall: String
}

struct Account: Codable {
    let privateKey: String
    let address: String
}

enum InternalError: Error {
    case unknownError
}

struct Ethereum {
    
    private static let network: Network = AlchemyNetwork(
        chain: "mainnet",
        apiKey: "xxx"
    )
    
    static func sign(message: String, account: Account) throws -> String {
        let ethPrivateKey = EthPrivateKey(hex: account.privateKey)
        
        let signature = SECP256k1Signature(
            privateKey: ethPrivateKey,
            message: UTF8StringBytes(string: message),
            hashFunction: SHA3(variant: .keccak256).calculate
        )
        let data = try ConcatenatedBytes(
            bytes: [
                signature.r(),
                signature.s(),
                EthNumber(value: signature.recoverID().value() + 27)
            ]
        ).value()
        return data.toPrefixedHexString()
    }
    
    static func signPersonal(message: String, account: Account) throws -> String {
        let ethPrivateKey = EthPrivateKey(hex: account.privateKey)
        let signed = SignedPersonalMessageBytes(message: message, signerKey: ethPrivateKey)
        let data = try signed.value().toPrefixedHexString()
        return data
    }
    
    static func sign(typedData: String, account: Account) throws -> String {
        let data = try EIP712TypedData(jsonString: typedData)
        let hash = EIP712Hash(domain: data.domain, typedData: data)
        let privateKey = EthPrivateKey(hex: account.privateKey)
        let signer = EIP712Signer(privateKey: privateKey)
        return try signer.signatureData(hash: hash).toPrefixedHexString()
    }
    
    static func sign(transaction: Transaction, account: Account) throws -> String {
        guard transaction.transactionsCount != nil, transaction.gasPrice != nil, transaction.gasEstimate != nil else {
            throw Errors.unknown
        }
        let bytes = signedTransactionBytes(transaction: transaction, account: account)
        return try bytes.value().toPrefixedHexString()
    }
    
    static func send(transaction: Transaction, account: Account) throws -> String {
        let bytes = signedTransactionBytes(transaction: transaction, account: account)
        let response = try SendRawTransactionProcedure(network: network, transactionBytes: bytes).call()
        guard let hash = response["result"].string else {
            throw Errors.unknown
        }
        return hash
    }
    
    private static func signedTransactionBytes(transaction: Transaction, account: Account) -> EthContractCallBytes {
        let senderKey = EthPrivateKey(hex: account.privateKey)
        let contractAddress = EthAddress(hex: transaction.recipientAddress)
        let weiAmount = EthNumber(hex: transaction.weiAmount)
        let functionCall = BytesFromHexString(hex: transaction.contractCall)

        let bytes: EthContractCallBytes
        if let gasPriceString = transaction.gasPrice {
            let gasPrice = EthNumber(hex: gasPriceString)
            if let gasEstimateString = transaction.gasEstimate, let transctionCountString = transaction.transactionsCount {
                let gasEstimate = EthNumber(hex: gasEstimateString)
                let transactionCount = EthNumber(hex: transctionCountString)
                
                bytes = EthContractCallBytes(networkID: NetworkID(network: network),
                                             transactionsCount: transactionCount,
                                             gasPrice: gasPrice,
                                             gasEstimate: gasEstimate,
                                             senderKey: senderKey,
                                             contractAddress: contractAddress,
                                             weiAmount: weiAmount,
                                             functionCall: functionCall)
            } else {
                bytes = EthContractCallBytes(network: network,
                                             gasPrice: gasPrice,
                                             senderKey: senderKey,
                                             contractAddress: contractAddress,
                                             weiAmount: weiAmount,
                                             functionCall: functionCall)
            }
        } else {
            bytes = EthContractCallBytes(network: network,
                                         senderKey: senderKey,
                                         contractAddress: contractAddress,
                                         weiAmount: weiAmount,
                                         functionCall: functionCall)
        }
        return bytes
    }
    
}
