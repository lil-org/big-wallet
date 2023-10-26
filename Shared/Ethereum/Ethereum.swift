// Copyright © 2021 Tokenary. All rights reserved.

import Foundation
import WalletCore

struct Ethereum {

    enum Error: Swift.Error {
        case invalidInputData
        case failedToSendTransaction
        case failedToSign
        case keyNotFound
    }

    private let queue = DispatchQueue(label: "Ethereum", qos: .default)
    private init() {}
    
    static let shared = Ethereum()
    
    func sign(data: Data, privateKey: WalletCore.PrivateKey) throws -> String {
        return try sign(data: data, privateKey: privateKey, addPrefix: false)
    }
    
    func signPersonalMessage(data: Data, privateKey: WalletCore.PrivateKey) throws -> String {
        return try sign(data: data, privateKey: privateKey, addPrefix: true)
    }
    
    func recover(signature: Data, message: Data) -> String? {
        guard let hash = prefixedDataHash(data: message),
              let publicKey = PublicKey.recover(signature: signature, message: hash),
              PublicKey.isValid(data: publicKey.data, type: publicKey.keyType) else {
                  return nil
              }
        return CoinType.ethereum.deriveAddressFromPublicKey(publicKey: publicKey)
    }
    
    private func prefixedDataHash(data: Data) -> Data? {
        let prefixString = "\u{19}Ethereum Signed Message:\n" + String(data.count)
        guard let prefixData = prefixString.data(using: .utf8) else { return nil }
        return Hash.keccak256(data: prefixData + data)
    }
    
    private func sign(data: Data, privateKey: WalletCore.PrivateKey, addPrefix: Bool) throws -> String {
        let digest: Data
        if addPrefix {
            guard let prefixedData = prefixedDataHash(data: data) else { throw Error.failedToSign }
            digest = prefixedData
        } else {
            digest = data
        }
        
        guard var signed = privateKey.sign(digest: digest, curve: CoinType.ethereum.curve) else { throw Error.failedToSign }
        signed[64] += 27
        return signed.hexString.withHexPrefix
    }
    
    func sign(typedData: String, privateKey: WalletCore.PrivateKey) throws -> String {
        let digest = EthereumAbi.encodeTyped(messageJson: typedData)
        guard var signed = privateKey.sign(digest: digest, curve: CoinType.ethereum.curve) else { throw Error.failedToSign }
        signed[64] += 27
        return signed.hexString.withHexPrefix
    }
    
    func send(transaction: Transaction, privateKey: WalletCore.PrivateKey, chain: EthereumNetwork) throws -> String {
        if Bool.random() {
            throw Error.failedToSendTransaction
        } else {
            let hash = "" // TODO: sign and send transaction
            return hash
        }
    }
    
    func prepareTransaction(_ transaction: Transaction, chain: EthereumNetwork, completion: @escaping (Transaction) -> Void) {
        var transaction = transaction
        
        if transaction.nonce == nil {
            getNonce(network: chain, from: transaction.from) { nonce in
                transaction.nonce = nonce
                completion(transaction)
            }
        }
        
        func getGasIfNeeded(gasPrice: String) {
            guard transaction.gas == nil else { return }
            getGas(network: chain, from: transaction.from, to: transaction.to, gasPrice: gasPrice, value: transaction.value, data: transaction.data) { gas in
                transaction.gas = gas
                completion(transaction)
            }
        }
        
        if let gasPrice = transaction.gasPrice {
            getGasIfNeeded(gasPrice: gasPrice)
        } else {
            getGasPrice(network: chain) { gasPrice in
                transaction.gasPrice = gasPrice
                completion(transaction)
                if let gasPrice = gasPrice {
                    getGasIfNeeded(gasPrice: gasPrice)
                }
            }
        }
    }
    
    private func getGas(network: EthereumNetwork, from: String, to: String, gasPrice: String, value: String?, data: String, completion: @escaping (String?) -> Void) {
        queue.async {
            let gas = "" // TODO: get hex for network
            DispatchQueue.main.async {
                completion(gas)
            }
        }
    }
    
    private func getGasPrice(network: EthereumNetwork, completion: @escaping (String?) -> Void) {
        queue.async {
            let gasPrice = "" // TODO: get hex for network
            DispatchQueue.main.async {
                completion(gasPrice)
            }
        }
    }
    
    private func getNonce(network: EthereumNetwork, from: String, completion: @escaping (String?) -> Void) {
        queue.async {
            let nonce = "" // TODO: get hex for network
            DispatchQueue.main.async {
                completion(nonce)
            }
        }
    }
    
}
