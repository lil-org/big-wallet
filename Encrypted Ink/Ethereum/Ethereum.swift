// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation
import Web3Swift
import CryptoSwift

struct Transaction {
    let transactionsCount: String
    let gasPrice: String
    let gasEstimate: String
    let recipientAddress: String
    let weiAmount: String
    let contractCall: String
}

struct Account {
    let privateKey: String
    let address: String
}

struct Ethereum {
    
    private static let network: Network = InfuraNetwork(
        chain: "mainnet",
        apiKey: "0c4d6dc730244b4185a6bde26f981bff"
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
        let bytes = signedTransactionBytes(transaction: transaction, account: account)
        return try bytes.value().toPrefixedHexString()
    }
    
    static func send(transaction: Transaction, account: Account) throws {
        let bytes = signedTransactionBytes(transaction: transaction, account: account)
        let response = try SendRawTransactionProcedure(
            network: network,
            transactionBytes: bytes).call()
    }
    
    private static func signedTransactionBytes(transaction: Transaction, account: Account) -> EthContractCallBytes {
        let transactionsCount = IntegerBytes(value: Int(transaction.transactionsCount)!)
        let gasPrice = BytesFromHexString(hex: transaction.gasPrice)
        let gasEstimate = BytesFromHexString(hex: transaction.gasEstimate)
        let senderKey = EthPrivateKey(hex: account.privateKey)
        let recipientAddress = BytesFromHexString(hex: transaction.recipientAddress)
        let weiAmount = BytesFromHexString(hex: transaction.weiAmount)
        let contractCall = BytesFromHexString(hex: transaction.contractCall)
        let bytes = EthContractCallBytes(
                    networkID: NetworkID(network: network),
                    transactionsCount: transactionsCount,
                    gasPrice: gasPrice,
                    gasEstimate: gasEstimate,
                    senderKey: senderKey,
                contractAddress: recipientAddress,
            weiAmount: weiAmount,
            functionCall: contractCall
        )
        return bytes
    }
    
}
