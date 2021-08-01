// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation
import Web3Swift
import CryptoSwift

struct Ethereum {

    enum Error: Swift.Error {
        case invalidInputData
        case failedToSendTransaction
        case keyNotFound
    }

    private let queue = DispatchQueue(label: "Ethereum", qos: .default)
    private init() {}
    
    static let shared = Ethereum()
    
    private let network: Network = AlchemyNetwork(
        chain: "mainnet",
        apiKey: Secrets.alchemy
    )
    
    func sign(message: String, wallet: InkWallet) throws -> String {
        guard let privateKeyString = wallet.ethereumPrivateKey else { throw Error.keyNotFound }
        let ethPrivateKey = EthPrivateKey(hex: privateKeyString)
        
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
    
    func signPersonal(message: String, wallet: InkWallet) throws -> String {
        guard let privateKeyString = wallet.ethereumPrivateKey else { throw Error.keyNotFound }
        let ethPrivateKey = EthPrivateKey(hex: privateKeyString)
        let signed = SignedPersonalMessageBytes(message: message, signerKey: ethPrivateKey)
        let data = try signed.value().toPrefixedHexString()
        return data
    }
    
    func sign(typedData: String, wallet: InkWallet) throws -> String {
        guard let privateKeyString = wallet.ethereumPrivateKey else { throw Error.keyNotFound }
        let data = try EIP712TypedData(jsonString: typedData)
        let hash = EIP712Hash(domain: data.domain, typedData: data)
        let privateKey = EthPrivateKey(hex: privateKeyString)
        let signer = EIP712Signer(privateKey: privateKey)
        return try signer.signatureData(hash: hash).toPrefixedHexString()
    }
    
    func send(transaction: Transaction, wallet: InkWallet) throws -> String {
        let bytes = try signedTransactionBytes(transaction: transaction, wallet: wallet)
        let response = try SendRawTransactionProcedure(network: network, transactionBytes: bytes).call()
        guard let hash = response["result"].string else {
            throw Error.failedToSendTransaction
        }
        return hash
    }
    
    private func signedTransactionBytes(transaction: Transaction, wallet: InkWallet) throws -> EthContractCallBytes {
        guard let privateKeyString = wallet.ethereumPrivateKey else { throw Error.keyNotFound }
        let senderKey = EthPrivateKey(hex: privateKeyString)
        let contractAddress = EthAddress(hex: transaction.to)
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
                                             weiAmount: transaction.weiAmount,
                                             functionCall: functionCall)
            } else {
                bytes = EthContractCallBytes(network: network,
                                             gasPrice: gasPrice,
                                             senderKey: senderKey,
                                             contractAddress: contractAddress,
                                             weiAmount: transaction.weiAmount,
                                             functionCall: functionCall)
            }
        } else {
            bytes = EthContractCallBytes(network: network,
                                         senderKey: senderKey,
                                         contractAddress: contractAddress,
                                         weiAmount: transaction.weiAmount,
                                         functionCall: functionCall)
        }
        return bytes
    }
    
    func prepareTransaction(_ transaction: Transaction, completion: @escaping (Transaction) -> Void) {
        var transaction = transaction
        
        if transaction.nonce == nil {
            getNonce(from: transaction.from) { nonce in
                transaction.nonce = nonce
                completion(transaction)
            }
        }
        
        func getGasIfNeeded(gasPrice: String) {
            guard transaction.gas == nil else { return }
            getGas(from: transaction.from, to: transaction.to, gasPrice: gasPrice, weiAmount: transaction.weiAmount, data: transaction.data) { gas in
                transaction.gas = gas
                completion(transaction)
            }
        }
        
        if let gasPrice = transaction.gasPrice {
            getGasIfNeeded(gasPrice: gasPrice)
        } else {
            getGasPrice { gasPrice in
                transaction.gasPrice = gasPrice
                completion(transaction)
                if let gasPrice = gasPrice {
                    getGasIfNeeded(gasPrice: gasPrice)
                }
            }
        }
        
    }
    
    private func getGas(from: String, to: String, gasPrice: String, weiAmount: EthNumber, data: String, completion: @escaping (String?) -> Void) {
        queue.async {
            let gas = try? EthGasEstimate(
                network: network,
                senderAddress: EthAddress(hex: from),
                recipientAddress: EthAddress(hex: to),
                gasEstimate: EthGasEstimate(
                    network: network,
                    senderAddress: EthAddress(hex: from),
                    recipientAddress: EthAddress(hex: to),
                    gasPrice: EthNumber(hex: gasPrice),
                    weiAmount: weiAmount,
                    contractCall: BytesFromHexString(hex: data)
                ),
                gasPrice: EthNumber(hex: gasPrice),
                weiAmount: weiAmount,
                contractCall: BytesFromHexString(hex: data)
            ).value().toHexString()
            DispatchQueue.main.async {
                completion(gas)
            }
        }
    }
    
    private func getGasPrice(completion: @escaping (String?) -> Void) {
        queue.async {
            let gasPrice = try? EthGasPrice(network: network).value().toHexString()
            DispatchQueue.main.async {
                completion(gasPrice)
            }
        }
    }
    
    private func getNonce(from: String, completion: @escaping (String?) -> Void) {
        queue.async {
            let nonce = try? EthTransactions(network: network, address: EthAddress(hex: from), blockChainState: PendingBlockChainState()).count().value().toHexString()
            DispatchQueue.main.async {
                completion(nonce)
            }
        }
    }
    
}
