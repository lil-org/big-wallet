// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation
import Web3Swift
import CryptoSwift

struct Ethereum {

    enum Errors: Error {
        case invalidInputData
        case failedToSendTransaction
    }
    
    private static let network: Network = AlchemyNetwork(
        chain: "mainnet",
        apiKey: Secrets.alchemy
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
    
    static func send(transaction: Transaction, account: Account) throws -> String {
        let bytes = signedTransactionBytes(transaction: transaction, account: account)
        let response = try SendRawTransactionProcedure(network: network, transactionBytes: bytes).call()
        guard let hash = response["result"].string else {
            throw Errors.failedToSendTransaction
        }
        return hash
    }
    
    private static func signedTransactionBytes(transaction: Transaction, account: Account) -> EthContractCallBytes {
        let senderKey = EthPrivateKey(hex: account.privateKey)
        let contractAddress = EthAddress(hex: transaction.to)
        let weiAmount: EthNumber
        if let value = transaction.value {
            weiAmount = EthNumber(hex: value)
        } else {
            weiAmount = EthNumber(value: 0)
        }
        let functionCall = BytesFromHexString(hex: transaction.data)
        let bytes: EthContractCallBytes
        if let gasPriceString = transaction.gasPrice {
            let gasPrice = EthNumber(hex: gasPriceString)
            if let gasEstimateString = transaction.gas,
               let transctionCountString = transaction.nonce {
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
    
    private static func getGas(network: Network, from: String, to: String, gasPrice: EthNumber, weiAmount: EthNumber, data: String, completion: @escaping (Data?) -> Void) {
        let gas = try? EthGasEstimate(
            network: network,
            senderAddress: EthAddress(hex: from),
            recipientAddress: EthAddress(hex: to),
            gasEstimate: EthGasEstimate(
                network: network,
                senderAddress: EthAddress(hex: from),
                recipientAddress: EthAddress(hex: to),
                gasPrice: gasPrice,
                weiAmount: weiAmount,
                contractCall: BytesFromHexString(hex: data)
            ),
            gasPrice: gasPrice,
            weiAmount: weiAmount,
            contractCall: BytesFromHexString(hex: data)
        ).value()
        completion(gas)
    }
    
    private static func getGasPrice(completion: @escaping (EthNumber) -> Void) {
        let gasPrice = EthNumber(hex: SimpleBytes { try EthGasPrice(network: network).value() })
        completion(gasPrice)
    }
    
    private static func getNonce(network: Network, from: String, completion: @escaping (Data?) -> Void) {
        let data = try? EthTransactions(network: network, address: EthAddress(hex: from), blockChainState: PendingBlockChainState()).count().value()
        completion(data)
    }
    
}
