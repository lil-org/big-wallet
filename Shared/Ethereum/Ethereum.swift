// ∅ 2026 lil org

import Foundation

enum TransactionPreparationFailure: Swift.Error, Equatable {
    case nonceUnavailable
    case gasPriceUnavailable
    case gasEstimationFailed
    case invalidTransaction
}

struct Ethereum {

    typealias TransactionInterpreter = (
        _ data: String,
        _ cancellation: EthereumRequestCancellation,
        _ completion: @escaping (String) -> Void
    ) -> Void

    enum Error: Swift.Error {
        case failedToSign
    }

    static let shared = Ethereum()
    private let rpc: EthereumRPCClient
    private let interpretTransaction: TransactionInterpreter

    init(
        rpc: EthereumRPCClient = EthereumRPC(),
        interpretTransaction: @escaping TransactionInterpreter = {
            data,
            cancellation,
            completion in
            TransactionInspector.shared.interpret(
                data: data,
                cancellation: cancellation,
                completion: completion
            )
        }
    ) {
        self.rpc = rpc
        self.interpretTransaction = interpretTransaction
    }
    
    func getBalance(network: EthereumNetwork, address: String, completion: @escaping (BigUInt) -> Void) {
        Self.performNativeBalanceRequest(for: network) {
            rpc.getBalance(
                endpoint: network.rpcEndpoint,
                for: address
            ) { result in
                guard case let .success(hex) = result, let balance = BigUInt(hexString: hex) else { return }
                DispatchQueue.main.async { completion(balance) }
            }
        }
    }

    static func performNativeBalanceRequest(for network: EthereumNetwork, request: () -> Void) {
        guard network.supportsNativeBalance else { return }
        request()
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
        return WalletCrypto.keccak256(parts: [prefixData, data])
    }
    
    private func sign(digest: Data, privateKey: WalletPrivateKey) throws -> String {
        guard var signed = privateKey.sign(digest: digest, coin: .ethereum),
              signed.count == 65,
              signed[64] <= 1 else { throw Error.failedToSign }
        signed[64] += 27
        return WalletCrypto.hexString(data: signed).withHexPrefix
    }
    
    func sign(typedData: String, privateKey: WalletPrivateKey) throws -> String {
        let digest = WalletCrypto.ethereumTypedDataDigest(messageJson: typedData)
        return try sign(digest: digest, privateKey: privateKey)
    }
    
    @discardableResult
    func prepareTransaction(
        _ transaction: Transaction,
        forceGasCheck: Bool,
        network: EthereumNetwork,
        onUpdate: @escaping (Transaction) -> Void,
        completion: @escaping (
            Result<Transaction, TransactionPreparationFailure>
        ) -> Void
    ) -> EthereumRequestCancellation {
        let cancellation = EthereumRequestCancellation()
        DispatchQueue.main.async {
            guard !cancellation.isCancelled else { return }
            var transaction = transaction
            var didFinish = false
            var nonceIsReady = transaction.nonce != nil
            var gasLaneIsReady = false
            var didResolveGasPrice = transaction.gasPrice != nil
            var didStartGasRequest = false
            let requiresGasEstimate =
                transaction.gas == nil || forceGasCheck

            func fail(_ failure: TransactionPreparationFailure) {
                guard !didFinish else { return }
                cancellation.cancel(performing: {
                    didFinish = true
                    completion(.failure(failure))
                })
            }

            func finishIfReady() {
                guard !cancellation.isCancelled,
                      !didFinish,
                      nonceIsReady,
                      gasLaneIsReady else {
                    return
                }
                guard transaction.isReadyForApproval(on: network) else {
                    fail(.invalidTransaction)
                    return
                }
                cancellation.performIfActive {
                    guard !didFinish else { return }
                    didFinish = true
                    completion(.success(transaction))
                }
            }

            func requestGas() {
                guard !cancellation.isCancelled,
                      !didFinish,
                      !didStartGasRequest else {
                    return
                }
                didStartGasRequest = true
                getGas(
                    network: network,
                    transaction: transaction,
                    cancellation: cancellation
                ) { gas in
                    guard !cancellation.isCancelled,
                          !didFinish,
                          !gasLaneIsReady else {
                        return
                    }
                    guard let gas else {
                        fail(.gasEstimationFailed)
                        return
                    }
                    transaction.gas = gas
                    gasLaneIsReady = true
                    cancellation.performIfActive {
                        onUpdate(transaction)
                    }
                    finishIfReady()
                }
            }

            func finishGasPriceResolution() {
                if requiresGasEstimate {
                    requestGas()
                } else {
                    gasLaneIsReady = true
                    finishIfReady()
                }
            }

            if Self.shouldInspect(transaction) {
                interpretTransaction(
                    transaction.data,
                    cancellation
                ) { interpretation in
                    DispatchQueue.main.async {
                        cancellation.performIfActive {
                            transaction.interpretation = interpretation
                            onUpdate(transaction)
                        }
                    }
                }
            }

            if nonceIsReady {
                finishIfReady()
            } else {
                getNonce(
                    network: network,
                    from: transaction.from,
                    cancellation: cancellation
                ) { nonce in
                    guard !cancellation.isCancelled,
                          !didFinish,
                          !nonceIsReady else {
                        return
                    }
                    guard let nonce else {
                        fail(.nonceUnavailable)
                        return
                    }
                    transaction.nonce = nonce
                    nonceIsReady = true
                    cancellation.performIfActive {
                        onUpdate(transaction)
                    }
                    finishIfReady()
                }
            }

            if didResolveGasPrice {
                finishGasPriceResolution()
            } else {
                getGasPrice(
                    network: network,
                    cancellation: cancellation
                ) { gasPrice in
                    guard !cancellation.isCancelled,
                          !didFinish,
                          !didResolveGasPrice else {
                        return
                    }
                    guard let gasPrice else {
                        fail(.gasPriceUnavailable)
                        return
                    }
                    transaction.gasPrice = gasPrice
                    didResolveGasPrice = true
                    cancellation.performIfActive {
                        onUpdate(transaction)
                    }
                    finishGasPriceResolution()
                }
            }

            finishIfReady()
        }
        return cancellation
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
        rpc.sendRawTransaction(
            endpoint: network.rpcEndpoint,
            signedTxData: WalletCrypto.hexString(data: signedTransaction).withHexPrefix
        ) { result in
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
    
    private func getGas(
        network: EthereumNetwork,
        transaction: Transaction,
        cancellation: EthereumRequestCancellation,
        completion: @escaping (String?) -> Void
    ) {
        rpc.estimateGas(
            endpoint: network.rpcEndpoint,
            transaction: transaction,
            cancellation: cancellation
        ) { result in
            guard !cancellation.isCancelled else { return }
            switch result {
            case .success(let estimatedGas):
                var updatedTransaction = transaction
                updatedTransaction.gas = estimatedGas
                rpc.estimateGas(
                    endpoint: network.rpcEndpoint,
                    transaction: updatedTransaction,
                    cancellation: cancellation
                ) { result in
                    guard !cancellation.isCancelled else { return }
                    switch result {
                    case .success(let gas):
                        DispatchQueue.main.async { completion(gas) }
                    case .failure:
                        DispatchQueue.main.async { completion(nil) }
                    }
                }
            case .failure:
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
    
    private func getGasPrice(
        network: EthereumNetwork,
        cancellation: EthereumRequestCancellation,
        completion: @escaping (String?) -> Void
    ) {
        rpc.fetchGasPrice(
            endpoint: network.rpcEndpoint,
            cancellation: cancellation
        ) { result in
            guard !cancellation.isCancelled else { return }
            switch result {
            case .success(let gasPrice):
                DispatchQueue.main.async { completion(gasPrice) }
            case .failure:
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
    
    private func getNonce(
        network: EthereumNetwork,
        from: String,
        cancellation: EthereumRequestCancellation,
        completion: @escaping (String?) -> Void
    ) {
        rpc.fetchNonce(
            endpoint: network.rpcEndpoint,
            for: from,
            cancellation: cancellation
        ) { result in
            guard !cancellation.isCancelled else { return }
            switch result {
            case .success(let nonce):
                DispatchQueue.main.async { completion(nonce) }
            case .failure:
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
    
}
