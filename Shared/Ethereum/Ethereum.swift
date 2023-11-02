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

    private init() {}
    static let shared = Ethereum()
    private let rpc = EthereumRPC()
    
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
    
    func prepareTransaction(_ transaction: Transaction, network: EthereumNetwork, completion: @escaping (Transaction) -> Void) {
        var transaction = transaction
        
        if transaction.nonce == nil {
            getNonce(network: network, from: transaction.from) { nonce in
                transaction.nonce = nonce
                completion(transaction)
            }
        }
        
        func getGasIfNeeded(gasPrice: String) {
            guard transaction.gas == nil else { return }
            getGas(network: network, transaction: transaction) { gas in
                transaction.gas = gas
                completion(transaction)
            }
        }
        
        if let gasPrice = transaction.gasPrice {
            getGasIfNeeded(gasPrice: gasPrice)
        } else {
            getGasPrice(network: network) { gasPrice in
                transaction.gasPrice = gasPrice
                completion(transaction)
                if let gasPrice = gasPrice {
                    getGasIfNeeded(gasPrice: gasPrice)
                }
            }
        }
    }
    
    func send(transaction: Transaction, privateKey: WalletCore.PrivateKey, network: EthereumNetwork, completion: @escaping (String?) -> Void) {
        guard let nonceHex = transaction.nonce?.cleanEvenHex,
              let gasPriceHex = transaction.gasPrice?.cleanEvenHex,
              let gasHex = transaction.gas?.cleanEvenHex,
              let valueHex = transaction.value?.cleanEvenHex,
              let chainID = Data(hexString: network.chainIdHexString.cleanEvenHex),
              let nonce = Data(hexString: nonceHex),
              let gasPrice = Data(hexString: gasPriceHex),
              let gasLimit = Data(hexString: gasHex),
              let amount = Data(hexString: valueHex),
              let data = Data(hexString: transaction.data.cleanEvenHex) else {
            completion(nil)
            return
        }
        
        let input = EthereumSigningInput.with {
            $0.chainID = chainID
            $0.nonce = nonce
            $0.gasPrice = gasPrice
            $0.gasLimit = gasLimit
            $0.toAddress = transaction.to
            $0.privateKey = privateKey.data
            $0.transaction = EthereumTransaction.with {
                $0.contractGeneric = EthereumTransaction.ContractGeneric.with {
                    $0.amount = amount
                    $0.data = data
                }
            }
        }
        
        let output: EthereumSigningOutput = AnySigner.sign(input: input, coin: .ethereum)
        rpc.sendRawTransaction(rpcUrl: network.nodeURLString, signedTxData: output.encoded.hexString.withHexPrefix) { result in
            DispatchQueue.main.async {
                if case let .success(txHash) = result {
                     completion(txHash)
                } else {
                    completion(nil)
                }
            }
        }
    }
    
    private func getGas(network: EthereumNetwork, transaction: Transaction, completion: @escaping (String?) -> Void) {
        rpc.estimateGas(rpcUrl: network.nodeURLString, transaction: transaction) { result in
            if case let .success(estimatedGas) = result {
                var updatedTransaction = transaction
                updatedTransaction.gas = estimatedGas
                rpc.estimateGas(rpcUrl: network.nodeURLString, transaction: updatedTransaction) { result in
                    if case let .success(gas) = result {
                        DispatchQueue.main.async { completion(gas) }
                    }
                }
            }
        }
    }
    
    private func getGasPrice(network: EthereumNetwork, completion: @escaping (String?) -> Void) {
        rpc.fetchGasPrice(rpcUrl: network.nodeURLString) { result in
            if case let .success(gasPrice) = result {
                DispatchQueue.main.async { completion(gasPrice) }
            }
        }
    }
    
    private func getNonce(network: EthereumNetwork, from: String, completion: @escaping (String?) -> Void) {
        rpc.fetchNonce(rpcUrl: network.nodeURLString, for: from) { result in
            if case let .success(nonce) = result {
                DispatchQueue.main.async { completion(nonce) }
            }
        }
    }
    
}
