// ∅ 2026 lil org

import Foundation

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
    
    func getBalance(network: EthereumNetwork, address: String, completion: @escaping (BigUInt) -> Void) {
        rpc.getBalance(rpcUrl: network.nodeURLString, for: address) { result in
            guard case let .success(hex) = result, let balance = BigUInt(hexString: hex) else { return }
            DispatchQueue.main.async { completion(balance) }
        }
    }
    
    func sign(data: Data, privateKey: WalletPrivateKey) throws -> String {
        return try sign(digest: data, privateKey: privateKey)
    }
    
    func signPersonalMessage(data: Data, privateKey: WalletPrivateKey) throws -> String {
        guard let digest = prefixedDataHash(data: data) else { throw Error.failedToSign }
        return try sign(digest: digest, privateKey: privateKey)
    }
    
    func recover(signature: Data, message: Data) -> String? {
        guard let hash = prefixedDataHash(data: message) else { return nil }
        return WalletCrypto.recoverEthereumAddress(signature: signature, messageHash: hash)
    }
    
    private func prefixedDataHash(data: Data) -> Data? {
        let prefixString = "\u{19}Ethereum Signed Message:\n" + String(data.count)
        guard let prefixData = prefixString.data(using: .utf8) else { return nil }
        return WalletCrypto.keccak256(data: prefixData + data)
    }
    
    private func sign(digest: Data, privateKey: WalletPrivateKey) throws -> String {
        guard WalletCrypto.isSupportedEthereumSigningDigest(digest),
              var signed = privateKey.sign(digest: digest, coin: .ethereum),
              signed.count == 65,
              signed[64] <= 1 else { throw Error.failedToSign }
        signed[64] += 27
        return WalletCrypto.hexString(data: signed).withHexPrefix
    }
    
    func sign(typedData: String, privateKey: WalletPrivateKey) throws -> String {
        let digest = WalletCrypto.ethereumTypedDataDigest(messageJson: typedData)
        return try sign(digest: digest, privateKey: privateKey)
    }
    
    func prepareTransaction(_ transaction: Transaction, forceGasCheck: Bool, network: EthereumNetwork, completion: @escaping (Transaction) -> Void) {
        var transaction = transaction
        
        if transaction.nonce == nil {
            getNonce(network: network, from: transaction.from) { nonce in
                transaction.nonce = nonce
                completion(transaction)
            }
        }
        
        func getGasIfNeeded(gasPrice: String) {
            guard transaction.gas == nil || forceGasCheck else { return }
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
        
        if Self.shouldInspect(transaction) {
            TransactionInspector.shared.interpret(data: transaction.data) { interpretation in
                transaction.interpretation = interpretation
                completion(transaction)
            }
        }
    }
    
    func send(transaction: Transaction, privateKey: WalletPrivateKey, network: EthereumNetwork, completion: @escaping (String?) -> Void) {
        guard let nonceHex = transaction.nonce?.cleanEvenHex,
              let gasPriceHex = transaction.gasPrice?.cleanEvenHex,
              let gasHex = transaction.gas?.cleanEvenHex,
              let valueHex = transaction.value?.cleanEvenHex,
              let chainID = WalletCrypto.hexData(string: network.chainIdHexString.cleanEvenHex),
              let nonce = WalletCrypto.hexData(string: nonceHex),
              let gasPrice = WalletCrypto.hexData(string: gasPriceHex),
              let gasLimit = WalletCrypto.hexData(string: gasHex),
              let amount = WalletCrypto.hexData(string: valueHex),
              let data = WalletCrypto.hexData(string: transaction.data.cleanEvenHex) else {
            completion(nil)
            return
        }
        
        guard let signedTransaction = WalletCrypto.signEthereumTransaction(chainID: chainID,
                                                                           nonce: nonce,
                                                                           gasPrice: gasPrice,
                                                                           gasLimit: gasLimit,
                                                                           toAddress: transaction.to,
                                                                           privateKey: privateKey,
                                                                           amount: amount,
                                                                           data: data) else {
            completion(nil)
            return
        }
        rpc.sendRawTransaction(rpcUrl: network.nodeURLString, signedTxData: WalletCrypto.hexString(data: signedTransaction).withHexPrefix) { result in
            DispatchQueue.main.async {
                if case let .success(txHash) = result {
                     completion(txHash)
                } else {
                    completion(nil)
                }
            }
        }
    }

    static func shouldInspect(_ transaction: Transaction) -> Bool {
        return transaction.interpretation == nil && !transaction.to.isEmpty
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
