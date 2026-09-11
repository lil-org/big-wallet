// ∅ 2026 lil org

import Foundation

enum TransactionPreparationFailure: Swift.Error, Equatable {
    case nonceUnavailable
    case gasPriceUnavailable
    case gasEstimationFailed
    case invalidTransaction
    case unsafeFees
}

enum EthereumSendFailure: Swift.Error, Equatable, Sendable {
    case invalidTransaction
    case failedToSign
    case rpc(EthereumRPCError)
    case transport
}

enum TransactionFeePreflightResult {
    case safe(Transaction, GasService.Estimate)
    case walletManagedUpdated(Transaction, GasService.Estimate)
    case userControlledUnsafe(Transaction, GasService.Estimate)
    case unavailable(Transaction, GasService.Estimate)
}

struct Ethereum {

    private enum FeeResolutionOutcome {
        case prepared(Transaction)
        case unsafeUserFee(Transaction)
        case unavailable(TransactionPreparationFailure)
    }

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
    private let gasService: GasService
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
        self.gasService = GasService(rpc: rpc)
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
        return try Self.sign(data: data, privateKey: privateKey)
    }

    static func sign(data: Data, privateKey: WalletPrivateKey) throws -> String {
        return try sign(digest: data, privateKey: privateKey)
    }
    
    func signPersonalMessage(data: Data, privateKey: WalletPrivateKey) throws -> String {
        return try Self.signPersonalMessage(data: data, privateKey: privateKey)
    }

    static func signPersonalMessage(
        data: Data,
        privateKey: WalletPrivateKey
    ) throws -> String {
        guard let digest = prefixedDataHash(data: data) else { throw Error.failedToSign }
        return try sign(digest: digest, privateKey: privateKey)
    }
    
    func recover(signature: Data, message: Data) -> String? {
        guard let hash = Self.prefixedDataHash(data: message) else { return nil }
        return WalletCrypto.recoverEthereumAddress(signature: signature, messageHash: hash)
    }
    
    private static func prefixedDataHash(data: Data) -> Data? {
        let prefixString = "\u{19}Ethereum Signed Message:\n" + String(data.count)
        guard let prefixData = prefixString.data(using: .utf8) else { return nil }
        return WalletCrypto.keccak256(parts: [prefixData, data])
    }
    
    private static func sign(digest: Data, privateKey: WalletPrivateKey) throws -> String {
        guard var signed = privateKey.sign(digest: digest, coin: .ethereum),
              signed.count == 65,
              signed[64] <= 1 else { throw Error.failedToSign }
        signed[64] += 27
        return WalletCrypto.hexString(data: signed).withHexPrefix
    }
    
    func sign(typedData: String, privateKey: WalletPrivateKey) throws -> String {
        return try Self.sign(typedData: typedData, privateKey: privateKey)
    }

    static func sign(typedData: String, privateKey: WalletPrivateKey) throws -> String {
        let digest = WalletCrypto.ethereumTypedDataDigest(messageJson: typedData)
        return try sign(digest: digest, privateKey: privateKey)
    }
    
    @discardableResult
    func prepareTransaction(
        _ transaction: Transaction,
        forceGasCheck: Bool,
        network: EthereumNetwork,
        onUpdate: @escaping (Transaction) -> Void,
        onFeeEstimate: @escaping (GasService.Estimate) -> Void = { _ in },
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
            var didResolveFee = false
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

            func finishFeeResolution() {
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

            resolveTransactionFee(
                transaction,
                network: network,
                cancellation: cancellation,
                onEstimate: onFeeEstimate
            ) { result in
                guard !cancellation.isCancelled,
                      !didFinish,
                      !didResolveFee else {
                    return
                }
                switch result {
                case .prepared(let resolved),
                     .unsafeUserFee(let resolved):
                    let didChangePreparedFields =
                        transaction.preparedFee != resolved.preparedFee
                            || transaction.feeProvenance
                                != resolved.feeProvenance
                            || transaction.currentBaseFeePerGas
                                != resolved.currentBaseFeePerGas
                            || transaction.nextBaseFeePerGas
                                != resolved.nextBaseFeePerGas
                    transaction.copyFeeState(from: resolved)
                    transaction.currentBaseFeePerGas =
                        resolved.currentBaseFeePerGas
                    transaction.nextBaseFeePerGas =
                        resolved.nextBaseFeePerGas
                    didResolveFee = true
                    if didChangePreparedFields {
                        cancellation.performIfActive {
                            onUpdate(transaction)
                        }
                    }
                    if case .unsafeUserFee = result {
                        fail(.unsafeFees)
                    } else {
                        finishFeeResolution()
                    }
                case .unavailable(let failure):
                    fail(failure)
                }
            }

            finishIfReady()
        }
        return cancellation
    }
    
    func send(
        transaction: Transaction,
        privateKey: WalletPrivateKey,
        network: EthereumNetwork,
        completion: @escaping (Result<String, EthereumSendFailure>) -> Void
    ) {
        switch Self.signedTransaction(
            transaction: transaction,
            privateKey: privateKey,
            network: network
        ) {
        case .success(let signedTransaction):
            sendSignedTransaction(
                signedTransaction,
                network: network,
                completion: completion
            )
        case .failure(let failure):
            completion(.failure(failure))
        }
    }

    static func signedTransaction(
        transaction: Transaction,
        privateKey: WalletPrivateKey,
        network: EthereumNetwork
    ) -> Result<String, EthereumSendFailure> {
        let parsedAmount: BigUInt?
        if transaction.value == nil || transaction.value == String.hexPrefix {
            parsedAmount = BigUInt()
        } else {
            parsedAmount = transaction.value.flatMap(
                {
                    EthereumQuantity.parseUInt256(
                        $0,
                        allowPrefixless: true
                    )
                }
            )
        }
        guard network.chainId > 0,
              transaction.isReadyForApproval(on: network),
              let nonce = transaction.nonce.flatMap(
                {
                    EthereumQuantity.parseUInt256(
                        $0,
                        allowPrefixless: true
                    )
                }
              ),
              let gasLimit = transaction.gasLimitValue,
              let amount = parsedAmount,
              let data = WalletCrypto.hexData(
                  string: transaction.data.cleanEvenHex
              ),
              let preparedFee = transaction.preparedFee,
              Transaction.isValidUInt256(amount) else {
            return .failure(.invalidTransaction)
        }

        let chainID = BigUInt(UInt64(network.chainId)).toData()
        let signedTransaction: Data?
        switch preparedFee {
        case .legacy(let gasPrice):
            signedTransaction = WalletCrypto.signEthereumTransaction(
                chainID: chainID,
                nonce: nonce.toData(),
                gasPrice: gasPrice.toData(),
                gasLimit: gasLimit.toData(),
                toAddress: transaction.to,
                privateKey: privateKey,
                amount: amount.toData(),
                data: data
            )
        case .eip1559(let maxPriorityFeePerGas, let maxFeePerGas):
            signedTransaction = WalletCrypto.signEthereumEIP1559Transaction(
                chainID: chainID,
                nonce: nonce.toData(),
                maxPriorityFeePerGas: maxPriorityFeePerGas.toData(),
                maxFeePerGas: maxFeePerGas.toData(),
                gasLimit: gasLimit.toData(),
                toAddress: transaction.to,
                privateKey: privateKey,
                amount: amount.toData(),
                data: data,
                accessList: transaction.accessList
            )
        }

        guard let signedTransaction else {
            return .failure(.failedToSign)
        }
        return .success(
            WalletCrypto.hexString(data: signedTransaction).withHexPrefix
        )
    }

    static func transactionHash(signedTransaction: String) -> String? {
        guard let data = WalletCrypto.hexData(signedTransaction), !data.isEmpty else {
            return nil
        }
        return WalletCrypto.hexString(
            data: WalletCrypto.keccak256(data: data)
        ).withHexPrefix
    }

    func sendSignedTransaction(
        _ signedTransaction: String,
        network: EthereumNetwork,
        completion: @escaping (Result<String, EthereumSendFailure>) -> Void
    ) {
        rpc.sendRawTransaction(
            endpoint: network.rpcEndpoint,
            signedTxData: signedTransaction
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let transactionHash):
                    completion(.success(transactionHash))
                case .failure(let error as EthereumRPCError):
                    completion(.failure(.rpc(error)))
                case .failure:
                    completion(.failure(.transport))
                }
            }
        }
    }

    @discardableResult
    func preflightTransactionFee(
        _ transaction: Transaction,
        network: EthereumNetwork,
        completion: @escaping (TransactionFeePreflightResult) -> Void
    ) -> EthereumRequestCancellation {
        let cancellation = EthereumRequestCancellation()
        gasService.fetchEstimate(
            network: network,
            cancellation: cancellation
        ) { estimate in
            guard !cancellation.isCancelled else { return }
            var candidate = transaction
            let baseFee = estimate.nextBaseFee ?? estimate.currentBaseFee
            estimate.applyBaseFeeContext(to: &candidate)

            guard network.chainId > 0 else {
                completion(.unavailable(candidate, estimate))
                return
            }
            if let endpointChainID = estimate.endpointChainID,
               endpointChainID != BigUInt(UInt64(network.chainId)) {
                completion(.unavailable(candidate, estimate))
                return
            }
            guard let preparedFee = candidate.preparedFee,
                  preparedFee.isStructurallyValid else {
                completion(.unavailable(candidate, estimate))
                return
            }
            guard let gasLimit = candidate.gasLimitValue,
                  !gasLimit.isZero else {
                completion(.unavailable(candidate, estimate))
                return
            }

            guard preparedFee.maximumNetworkFee(gasLimit: gasLimit) != nil else {
                if candidate.feeProvenance.containsUserControlledValue(
                    for: preparedFee
                ) {
                    completion(.userControlledUnsafe(candidate, estimate))
                } else {
                    completion(.unavailable(candidate, estimate))
                }
                return
            }

            let isSafe: Bool
            switch (estimate.support, preparedFee) {
            case (.legacy, .legacy):
                isSafe = true
            case (.eip1559, _):
                isSafe = baseFee.map {
                    preparedFee.hasSufficientEffectivePriorityFee(
                        baseFeePerGas: $0
                    )
                } ?? false
            case (.unknown, _) where candidate.feeProvenance
                .containsUserControlledValue(for: preparedFee):
                isSafe = candidate.feeBasisBaseFeePerGas.map {
                    preparedFee.hasSufficientEffectivePriorityFee(
                        baseFeePerGas: $0
                    )
                } ?? true
            default:
                isSafe = false
            }

            guard !isSafe else {
                completion(.safe(candidate, estimate))
                return
            }
            guard estimate.support == .eip1559,
                  let baseFee else {
                if estimate.support == .unknown,
                   candidate.feeProvenance.containsUserControlledValue(
                       for: preparedFee
                   ) {
                    completion(.userControlledUnsafe(candidate, estimate))
                } else {
                    completion(.unavailable(candidate, estimate))
                }
                return
            }

            let updatedFee: PreparedTransactionFee?
            let updatedProvenance: TransactionFeeProvenance
            switch preparedFee {
            case .legacy(let existingGasPrice):
                let source = candidate.feeProvenance.gasPrice
                    ?? candidate.feeSource
                guard source.isWalletManaged else {
                    completion(.userControlledUnsafe(candidate, estimate))
                    return
                }
                let priority: BigUInt
                if source == .slider {
                    if let previousBaseFee =
                        transaction.feeBasisBaseFeePerGas,
                       existingGasPrice > previousBaseFee {
                        priority = existingGasPrice - previousBaseFee
                    } else {
                        guard let recommendedPriority =
                            estimate.info?.recommendedPriorityFee else {
                            completion(.unavailable(candidate, estimate))
                            return
                        }
                        priority = recommendedPriority
                    }
                } else {
                    guard let recommendedPriority =
                        estimate.info?.recommendedPriorityFee else {
                        completion(.unavailable(candidate, estimate))
                        return
                    }
                    priority = recommendedPriority
                }
                let gasPrice: BigUInt?
                if source == .slider {
                    let sliderGasPrice = baseFee + priority
                    gasPrice = Transaction.isValidUInt256(sliderGasPrice)
                        ? sliderGasPrice
                        : nil
                } else {
                    gasPrice = GasService.suggestedLegacyGasPrice(
                        baseFeePerGas: baseFee,
                        priorityFeePerGas: priority
                    )
                }
                updatedFee = gasPrice.map { .legacy(gasPrice: $0) }
                updatedProvenance = TransactionFeeProvenance(
                    gasPrice: source
                )
            case .eip1559(
                let existingPriority,
                let existingMaxFee
            ):
                let prioritySource =
                    candidate.feeProvenance.maxPriorityFeePerGas
                        ?? candidate.feeSource
                let maxFeeSource = candidate.feeProvenance.maxFeePerGas
                    ?? candidate.feeSource
                let priority: BigUInt
                if prioritySource.isUserControlled ||
                    prioritySource == .slider {
                    priority = existingPriority
                } else {
                    if maxFeeSource.isUserControlled,
                       existingMaxFee <= baseFee {
                        completion(
                            .userControlledUnsafe(candidate, estimate)
                        )
                        return
                    }
                    guard let recommendedPriority =
                        estimate.info?.recommendedPriorityFee else {
                        completion(.unavailable(candidate, estimate))
                        return
                    }
                    priority = recommendedPriority
                }

                let maxFee: BigUInt
                if maxFeeSource.isUserControlled {
                    maxFee = existingMaxFee
                } else {
                    guard let recommended = PreparedTransactionFee
                        .recommendedEIP1559(
                            baseFeePerGas: baseFee,
                            maxPriorityFeePerGas: priority
                        ) else {
                        if prioritySource.isUserControlled {
                            completion(
                                .userControlledUnsafe(candidate, estimate)
                            )
                        } else {
                            completion(.unavailable(candidate, estimate))
                        }
                        return
                    }
                    maxFee = recommended.feeCapPerGas
                }
                let fee = PreparedTransactionFee.eip1559(
                    maxPriorityFeePerGas: priority,
                    maxFeePerGas: maxFee
                )
                updatedFee = fee.hasSufficientEffectivePriorityFee(
                    baseFeePerGas: baseFee
                ) ? fee : nil
                updatedProvenance = TransactionFeeProvenance(
                    maxPriorityFeePerGas: prioritySource,
                    maxFeePerGas: maxFeeSource
                )
            }
            guard let updatedFee,
                  updatedFee.isStructurallyValid else {
                if candidate.feeProvenance.containsUserControlledValue {
                    completion(.userControlledUnsafe(candidate, estimate))
                } else {
                    completion(.unavailable(candidate, estimate))
                }
                return
            }
            guard updatedFee.maximumNetworkFee(gasLimit: gasLimit) != nil else {
                completion(.unavailable(candidate, estimate))
                return
            }
            candidate.replacePreparedFee(
                updatedFee,
                provenance: updatedProvenance
            )
            completion(.walletManagedUpdated(candidate, estimate))
        }
        return cancellation
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
                guard let parsedGas = EthereumQuantity.parseUInt256(estimatedGas),
                      !parsedGas.isZero
                else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
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
                        let parsedGas = EthereumQuantity.parseUInt256(gas)
                        let validatedGas =
                            parsedGas == nil || parsedGas?.isZero == true
                                ? nil
                                : gas
                        DispatchQueue.main.async {
                            completion(validatedGas)
                        }
                    case .failure:
                        DispatchQueue.main.async { completion(nil) }
                    }
                }
            case .failure:
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
    
    private func resolveTransactionFee(
        _ transaction: Transaction,
        network: EthereumNetwork,
        cancellation: EthereumRequestCancellation,
        onEstimate: @escaping (GasService.Estimate) -> Void,
        completion: @escaping (FeeResolutionOutcome) -> Void
    ) {
        guard transaction.feeIntent.isStructurallyValid else {
            completion(.unavailable(.invalidTransaction))
            return
        }
        gasService.fetchEstimate(
            network: network,
            cancellation: cancellation
        ) { estimate in
            guard !cancellation.isCancelled else { return }
            var resolved = transaction
            let previousBaseFee = transaction.feeBasisBaseFeePerGas
            let baseFee = estimate.nextBaseFee ?? estimate.currentBaseFee
            estimate.applyBaseFeeContext(to: &resolved)

            guard network.chainId > 0 else {
                completion(.unavailable(.gasPriceUnavailable))
                return
            }
            if let endpointChainID = estimate.endpointChainID,
               endpointChainID != BigUInt(UInt64(network.chainId)) {
                completion(.unavailable(.gasPriceUnavailable))
                return
            }
            onEstimate(estimate)

            func unsafeUserFee() {
                completion(.unsafeUserFee(resolved))
            }

            func unavailable(
                _ failure: TransactionPreparationFailure
            ) {
                completion(.unavailable(failure))
            }

            func apply(
                _ fee: PreparedTransactionFee,
                source: TransactionFeeSource,
                preservingExistingSources: Bool
            ) -> Bool {
                guard fee.isStructurallyValid else { return false }
                if resolved.preparedFee == fee {
                    var provenance = resolved.feeProvenance
                    if preservingExistingSources {
                        provenance.fillMissingSources(
                            for: fee,
                            with: source
                        )
                    } else if resolved.feeSource != source {
                        provenance = TransactionFeeProvenance(
                            source: source,
                            for: fee
                        )
                    }
                    resolved.replaceFeeProvenance(provenance)
                    return true
                }
                resolved.setPreparedFee(
                    fee,
                    source: source,
                    preservingExistingSources: preservingExistingSources
                )
                return true
            }

            if resolved.feeSource == .slider,
               let sliderFee = resolved.preparedFee {
                let refreshedFee: PreparedTransactionFee?
                switch sliderFee {
                case .eip1559(let priorityFee, _):
                    refreshedFee = baseFee.flatMap {
                        PreparedTransactionFee.recommendedEIP1559(
                            baseFeePerGas: $0,
                            maxPriorityFeePerGas: priorityFee
                        )
                    }
                case .legacy(let gasPrice):
                    if estimate.support == .legacy {
                        refreshedFee = .legacy(gasPrice: gasPrice)
                    } else if estimate.support == .eip1559,
                              let baseFee {
                        let priorityFee: BigUInt
                        if let previousBaseFee,
                           gasPrice > previousBaseFee {
                            priorityFee = gasPrice - previousBaseFee
                        } else {
                            guard let recommendedPriority =
                                estimate.info?.recommendedPriorityFee else {
                                unavailable(.gasPriceUnavailable)
                                return
                            }
                            priorityFee = recommendedPriority
                        }
                        let refreshedGasPrice = baseFee + priorityFee
                        refreshedFee = Transaction.isValidUInt256(
                            refreshedGasPrice
                        ) ? .legacy(gasPrice: refreshedGasPrice) : nil
                    } else {
                        refreshedFee = nil
                    }
                }
                guard let refreshedFee,
                      apply(
                          refreshedFee,
                          source: .slider,
                          preservingExistingSources: false
                      ) else {
                    unavailable(.invalidTransaction)
                    return
                }
                completion(.prepared(resolved))
                return
            }

            switch resolved.feeIntent {
            case .automatic:
                switch estimate.support {
                case .eip1559:
                    guard let baseFee else {
                        unavailable(.gasPriceUnavailable)
                        return
                    }
                    if case .some(.legacy(let gasPrice)) =
                        resolved.preparedFee,
                       resolved.feeProvenance.gasPrice?
                        .isUserControlled == true {
                        guard PreparedTransactionFee
                            .legacy(gasPrice: gasPrice)
                            .hasSufficientEffectivePriorityFee(
                                baseFeePerGas: baseFee
                            ) else {
                            unsafeUserFee()
                            return
                        }
                        break
                    }

                    let prioritySource =
                        resolved.feeProvenance.maxPriorityFeePerGas
                            ?? .automatic
                    let maxFeeSource =
                        resolved.feeProvenance.maxFeePerGas ?? .automatic
                    let priorityFee: BigUInt
                    if prioritySource.isUserControlled
                        || prioritySource == .slider {
                        guard let existingPriority =
                            resolved.maxPriorityFeePerGasValue else {
                            unsafeUserFee()
                            return
                        }
                        priorityFee = existingPriority
                    } else {
                        if maxFeeSource.isUserControlled,
                           let existingMaxFee =
                            resolved.maxFeePerGasValue,
                           existingMaxFee <= baseFee {
                            unsafeUserFee()
                            return
                        }
                        guard let recommendedPriority =
                            estimate.info?.recommendedPriorityFee else {
                            unavailable(.gasPriceUnavailable)
                            return
                        }
                        priorityFee = recommendedPriority
                    }

                    let fee: PreparedTransactionFee
                    if maxFeeSource.isUserControlled {
                        guard let existingMaxFee =
                            resolved.maxFeePerGasValue else {
                            unsafeUserFee()
                            return
                        }
                        fee = .eip1559(
                            maxPriorityFeePerGas: priorityFee,
                            maxFeePerGas: existingMaxFee
                        )
                    } else {
                        guard let recommended =
                            PreparedTransactionFee.recommendedEIP1559(
                              baseFeePerGas: baseFee,
                              maxPriorityFeePerGas: priorityFee
                            ) else {
                            if prioritySource.isUserControlled {
                                unsafeUserFee()
                            } else {
                                unavailable(.gasPriceUnavailable)
                            }
                            return
                        }
                        fee = recommended
                    }
                    guard fee.hasSufficientEffectivePriorityFee(
                        baseFeePerGas: baseFee
                    ) else {
                        if prioritySource.isUserControlled
                            || maxFeeSource.isUserControlled {
                            unsafeUserFee()
                        } else {
                            unavailable(.gasPriceUnavailable)
                        }
                        return
                    }
                    guard apply(
                        fee,
                        source: .automatic,
                        preservingExistingSources: true
                    ) else {
                        if prioritySource.isUserControlled
                            || maxFeeSource.isUserControlled {
                            unsafeUserFee()
                        } else {
                            unavailable(.gasPriceUnavailable)
                        }
                        return
                    }
                case .legacy:
                    if resolved.feeProvenance.gasPrice?
                        .isUserControlled == true,
                       let existingFee = resolved.preparedFee,
                       existingFee.gasPrice != nil {
                        guard existingFee.isStructurallyValid,
                              existingFee.gasPrice.map({
                                  Transaction.isValidGasPrice($0, on: network)
                              }) == true else {
                            unsafeUserFee()
                            return
                        }
                        break
                    }
                    guard let gasPrice = estimate.gasPrice,
                          apply(
                              .legacy(gasPrice: gasPrice),
                              source: .automatic,
                              preservingExistingSources: false
                          ) else {
                        unavailable(.gasPriceUnavailable)
                        return
                    }
                case .unknown:
                    if let existingFee = resolved.preparedFee,
                       existingFee.isStructurallyValid,
                       resolved.feeProvenance.containsUserControlledValue(
                           for: existingFee
                       ),
                       existingFee.gasPrice.map({
                           Transaction.isValidGasPrice($0, on: network)
                       }) != false {
                        break
                    }
                    unavailable(.gasPriceUnavailable)
                    return
                }

            case .legacy(let requestedGasPrice):
                let gasPriceSource = resolved.feeProvenance.gasPrice
                    ?? (requestedGasPrice == nil ? .automatic : .dapp)
                var candidateGasPrice: BigUInt?
                if gasPriceSource.isUserControlled {
                    candidateGasPrice =
                        resolved.preparedFee?.gasPrice ?? requestedGasPrice
                } else if estimate.support == .eip1559,
                          let baseFee {
                    guard let priorityFee =
                        estimate.info?.recommendedPriorityFee else {
                        unavailable(.gasPriceUnavailable)
                        return
                    }
                    guard let derivedGasPrice = GasService
                        .suggestedLegacyGasPrice(
                            baseFeePerGas: baseFee,
                            priorityFeePerGas: priorityFee
                        ) else {
                        unavailable(.invalidTransaction)
                        return
                    }
                    candidateGasPrice = derivedGasPrice
                } else {
                    candidateGasPrice = estimate.gasPrice
                }
                guard var gasPrice = candidateGasPrice else {
                    unavailable(.gasPriceUnavailable)
                    return
                }

                if estimate.support == .eip1559 {
                    guard let baseFee else {
                        unavailable(.gasPriceUnavailable)
                        return
                    }
                    if gasPriceSource.isWalletManaged {
                        let minimum = baseFee
                            + PreparedTransactionFee.minimumPriorityFeePerGas
                        guard Transaction.isValidUInt256(minimum) else {
                            unavailable(.invalidTransaction)
                            return
                        }
                        if gasPrice < minimum {
                            gasPrice = minimum
                        }
                    } else if gasPrice < baseFee {
                        unsafeUserFee()
                        return
                    }
                }
                guard Transaction.isValidGasPrice(gasPrice, on: network) else {
                    if gasPriceSource.isUserControlled {
                        unsafeUserFee()
                    } else {
                        unavailable(.gasPriceUnavailable)
                    }
                    return
                }
                guard apply(
                    .legacy(gasPrice: gasPrice),
                    source: gasPriceSource,
                    preservingExistingSources: true
                ) else {
                    if gasPriceSource.isUserControlled {
                        unsafeUserFee()
                    } else {
                        unavailable(.invalidTransaction)
                    }
                    return
                }

            case .eip1559(
                let requestedPriorityFee,
                let requestedMaxFee
            ):
                let prioritySource =
                    resolved.feeProvenance.maxPriorityFeePerGas
                        ?? (requestedPriorityFee == nil ? .automatic : .dapp)
                let maxFeeSource = resolved.feeProvenance.maxFeePerGas
                    ?? (requestedMaxFee == nil ? .automatic : .dapp)
                guard estimate.support == .eip1559,
                      let baseFee else {
                    guard estimate.support == .unknown,
                          prioritySource.isUserControlled,
                          maxFeeSource.isUserControlled,
                          let priority =
                            resolved.preparedFee?.maxPriorityFeePerGas
                                ?? requestedPriorityFee,
                          let maxFee = resolved.preparedFee?.maxFeePerGas
                                ?? requestedMaxFee,
                          apply(
                              .eip1559(
                                  maxPriorityFeePerGas: priority,
                                  maxFeePerGas: maxFee
                              ),
                              source: .automatic,
                              preservingExistingSources: true
                          ) else {
                        unavailable(.gasPriceUnavailable)
                        return
                    }
                    break
                }
                let priorityFee: BigUInt
                if prioritySource.isUserControlled
                    || prioritySource == .slider {
                    guard let controlledPriority =
                        resolved.preparedFee?.maxPriorityFeePerGas
                            ?? requestedPriorityFee else {
                        unsafeUserFee()
                        return
                    }
                    priorityFee = controlledPriority
                } else {
                    if maxFeeSource.isUserControlled,
                       let controlledMaxFee =
                        resolved.preparedFee?.maxFeePerGas
                            ?? requestedMaxFee,
                       controlledMaxFee <= baseFee {
                        unsafeUserFee()
                        return
                    }
                    guard let recommendedPriority =
                        estimate.info?.recommendedPriorityFee else {
                        unavailable(.gasPriceUnavailable)
                        return
                    }
                    priorityFee = recommendedPriority
                }

                let maxFee: BigUInt
                if maxFeeSource.isUserControlled {
                    guard let controlledMaxFee =
                        resolved.preparedFee?.maxFeePerGas
                            ?? requestedMaxFee else {
                        unsafeUserFee()
                        return
                    }
                    maxFee = controlledMaxFee
                } else {
                    guard let recommended = PreparedTransactionFee
                        .recommendedEIP1559(
                            baseFeePerGas: baseFee,
                            maxPriorityFeePerGas: priorityFee
                        ) else {
                        if prioritySource.isUserControlled {
                            unsafeUserFee()
                        } else {
                            unavailable(.invalidTransaction)
                        }
                        return
                    }
                    maxFee = recommended.feeCapPerGas
                }
                let fee = PreparedTransactionFee.eip1559(
                    maxPriorityFeePerGas: priorityFee,
                    maxFeePerGas: maxFee
                )
                guard fee.hasSufficientEffectivePriorityFee(
                    baseFeePerGas: baseFee
                ) else {
                    if prioritySource.isUserControlled
                        || maxFeeSource.isUserControlled {
                        unsafeUserFee()
                    } else {
                        unavailable(.invalidTransaction)
                    }
                    return
                }
                guard apply(
                    fee,
                    source: .automatic,
                    preservingExistingSources: true
                ) else {
                    if prioritySource.isUserControlled
                        || maxFeeSource.isUserControlled {
                        unsafeUserFee()
                    } else {
                        unavailable(.invalidTransaction)
                    }
                    return
                }
            }

            if estimate.support == .unknown,
               let basis = resolved.feeBasisBaseFeePerGas,
               let resolvedFee = resolved.preparedFee,
               !resolvedFee.hasSufficientEffectivePriorityFee(
                   baseFeePerGas: basis
               ) {
                if resolved.feeProvenance.containsUserControlledValue(
                    for: resolvedFee
                ) {
                    unsafeUserFee()
                } else {
                    unavailable(.gasPriceUnavailable)
                }
                return
            }

            completion(.prepared(resolved))
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
                let validatedNonce =
                    EthereumQuantity.parseUInt256(nonce) == nil
                        ? nil
                        : nonce
                DispatchQueue.main.async {
                    completion(validatedNonce)
                }
            case .failure:
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
    
}
