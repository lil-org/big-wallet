// ∅ 2026 lil org

import Foundation

enum TransactionPreparationFailure: Swift.Error, Equatable, Sendable {
    case nonceUnavailable
    case gasPriceUnavailable
    case gasEstimationFailed
    case invalidTransaction
    case unsafeFees
}

enum EthereumSendFailure: Swift.Error, Equatable, Sendable {
    case rpc(EthereumRPCError)
    case transport
}

enum TransactionFeePreflightResult: Sendable {
    case safe(Transaction, GasService.Estimate)
    case walletManagedUpdated(Transaction, GasService.Estimate)
    case userControlledUnsafe(Transaction, GasService.Estimate)
    case unavailable(Transaction, GasService.Estimate)
}

enum TransactionPreparationEvent: Sendable {
    case transactionUpdated(Transaction)
    case feeEstimate(GasService.Estimate)
    case ready(Transaction)
}

struct Ethereum: Sendable {

    private enum FeeResolutionOutcome: Sendable {
        case prepared(Transaction)
        case unsafeUserFee(Transaction)
        case unavailable(TransactionPreparationFailure)
    }

    typealias TransactionInterpreter = @Sendable (String) async throws -> String?

    enum SigningFailure: Swift.Error, Equatable, Sendable {
        case invalidTransaction
        case failedToSign
    }

    static let shared = Ethereum()
    private let rpc: any EthereumRPCClient
    private let gasService: GasService
    private let interpretTransaction: TransactionInterpreter

    init(
        rpc: any EthereumRPCClient = EthereumRPC(),
        interpretTransaction: @escaping TransactionInterpreter = {
            try await TransactionInspector.shared.interpret(data: $0)
        }
    ) {
        self.rpc = rpc
        self.gasService = GasService(rpc: rpc)
        self.interpretTransaction = interpretTransaction
    }

    func getBalance(network: EthereumNetwork, address: String) async throws -> BigUInt? {
        try Task.checkCancellation()
        guard network.supportsNativeBalance else { return nil }
        let encoded = try await rpc.getBalance(endpoint: network.rpcEndpoint, for: address)
        try Task.checkCancellation()
        guard let balance = BigUInt(hexString: encoded) else { throw EthereumRPCError.unknown }
        return balance
    }

    
    static func signPersonalMessage(
        data: Data,
        privateKey: WalletPrivateKey
    ) throws -> String {
        guard let digest = prefixedDataHash(data: data) else { throw SigningFailure.failedToSign }
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
              signed[64] <= 1 else { throw SigningFailure.failedToSign }
        signed[64] += 27
        return WalletCrypto.hexString(data: signed).withHexPrefix
    }
    
    static func sign(typedData: String, privateKey: WalletPrivateKey) throws -> String {
        let digest = WalletCrypto.ethereumTypedDataDigest(messageJson: typedData)
        return try sign(digest: digest, privateKey: privateKey)
    }
    
    private enum PreparationStep: Sendable {
        case nonce(String)
        case estimate(GasService.Estimate)
        case gas(String)
        case interpretation(String?)
    }

    func prepareTransaction(
        _ transaction: Transaction,
        forceGasCheck: Bool,
        network: EthereumNetwork
    ) -> AsyncThrowingStream<TransactionPreparationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await withThrowingTaskGroup(of: PreparationStep.self) { group in
                    do {
                        try Task.checkCancellation()
                        guard transaction.feeIntent.isStructurallyValid else {
                            throw TransactionPreparationFailure.invalidTransaction
                        }
                        var current = transaction
                        var nonceIsReady = current.nonce != nil
                        var feeIsReady = false
                        var gasIsReady = false
                        var didBecomeReady = false
                        let requiresGasEstimate = current.gas == nil || forceGasCheck

                        if !nonceIsReady {
                            group.addTask {
                                .nonce(try await getNonce(network: network, from: transaction.from))
                            }
                        }
                        group.addTask {
                            .estimate(try await gasService.fetchEstimate(network: network))
                        }
                        if Self.shouldInspect(transaction) {
                            group.addTask {
                                .interpretation(try? await interpretTransaction(transaction.data))
                            }
                        }

                        while let step = try await group.next() {
                            try Task.checkCancellation()
                            switch step {
                            case .nonce(let nonce):
                                current.nonce = nonce
                                nonceIsReady = true
                                continuation.yield(.transactionUpdated(current))
                            case .estimate(let estimate):
                                if network.chainId > 0,
                                    estimate.endpointChainID == nil
                                        || estimate.endpointChainID == BigUInt(UInt64(network.chainId))
                                {
                                    continuation.yield(.feeEstimate(estimate))
                                }
                                let outcome = Self.resolveTransactionFee(current, network: network, estimate: estimate)
                                let resolved: Transaction
                                switch outcome {
                                case .prepared(let value), .unsafeUserFee(let value):
                                    resolved = value
                                case .unavailable(let failure):
                                    throw failure
                                }
                                let didChange =
                                    current.preparedFee != resolved.preparedFee
                                    || current.feeProvenance != resolved.feeProvenance
                                    || current.currentBaseFeePerGas != resolved.currentBaseFeePerGas
                                    || current.nextBaseFeePerGas != resolved.nextBaseFeePerGas
                                current.copyFeeState(from: resolved)
                                current.currentBaseFeePerGas = resolved.currentBaseFeePerGas
                                current.nextBaseFeePerGas = resolved.nextBaseFeePerGas
                                feeIsReady = true
                                if didChange { continuation.yield(.transactionUpdated(current)) }
                                if case .unsafeUserFee = outcome { throw TransactionPreparationFailure.unsafeFees }
                                if requiresGasEstimate {
                                    let candidate = current
                                    group.addTask {
                                        .gas(try await getGas(network: network, transaction: candidate))
                                    }
                                } else {
                                    gasIsReady = true
                                }
                            case .gas(let gas):
                                current.gas = gas
                                gasIsReady = true
                                continuation.yield(.transactionUpdated(current))
                            case .interpretation(let interpretation):
                                if let interpretation {
                                    current.interpretation = interpretation
                                    continuation.yield(.transactionUpdated(current))
                                }
                            }
                            if !didBecomeReady, nonceIsReady, feeIsReady, gasIsReady {
                                guard current.isReadyForApproval(on: network) else {
                                    throw TransactionPreparationFailure.invalidTransaction
                                }
                                didBecomeReady = true
                                continuation.yield(.ready(current))
                            }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                        group.cancelAll()
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func signedTransaction(
        transaction: Transaction,
        privateKey: WalletPrivateKey,
        network: EthereumNetwork
    ) -> Result<String, SigningFailure> {
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

    func sendSignedTransaction(_ signedTransaction: String, network: EthereumNetwork) async throws -> String {
        do {
            let result = try await rpc.sendRawTransaction(endpoint: network.rpcEndpoint, signedTxData: signedTransaction)
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as EthereumRPCError {
            try Task.checkCancellation()
            throw EthereumSendFailure.rpc(error)
        } catch {
            try Task.checkCancellation()
            throw EthereumSendFailure.transport
        }
    }

    func preflightTransactionFee(_ transaction: Transaction, network: EthereumNetwork) async throws
        -> TransactionFeePreflightResult
    {
        let estimate = try await gasService.fetchEstimate(network: network)
        try Task.checkCancellation()
        return Self.evaluatePreflight(transaction, network: network, estimate: estimate)
    }

    private static func evaluatePreflight(
        _ transaction: Transaction, network: EthereumNetwork, estimate: GasService.Estimate
    ) -> TransactionFeePreflightResult {
        var candidate = transaction
        let baseFee = estimate.nextBaseFee ?? estimate.currentBaseFee
        estimate.applyBaseFeeContext(to: &candidate)

        guard network.chainId > 0 else {
            return .unavailable(candidate, estimate)
        }
        if let endpointChainID = estimate.endpointChainID,
            endpointChainID != BigUInt(UInt64(network.chainId))
        {
            return .unavailable(candidate, estimate)
        }
        guard let preparedFee = candidate.preparedFee,
            preparedFee.isStructurallyValid
        else {
            return .unavailable(candidate, estimate)
        }
        guard let gasLimit = candidate.gasLimitValue,
            !gasLimit.isZero
        else {
            return .unavailable(candidate, estimate)
        }

        guard preparedFee.maximumNetworkFee(gasLimit: gasLimit) != nil else {
            if candidate.feeProvenance.containsUserControlledValue(
                for: preparedFee
            ) {
                return .userControlledUnsafe(candidate, estimate)
            } else {
                return .unavailable(candidate, estimate)
            }
        }

        let isSafe: Bool
        switch (estimate.support, preparedFee) {
        case (.legacy, .legacy):
            isSafe = true
        case (.eip1559, _):
            isSafe =
                baseFee.map {
                    preparedFee.hasSufficientEffectivePriorityFee(
                        baseFeePerGas: $0
                    )
                } ?? false
        case (.unknown, _)
        where candidate.feeProvenance
            .containsUserControlledValue(for: preparedFee):
            isSafe =
                candidate.feeBasisBaseFeePerGas.map {
                    preparedFee.hasSufficientEffectivePriorityFee(
                        baseFeePerGas: $0
                    )
                } ?? true
        default:
            isSafe = false
        }

        guard !isSafe else {
            return .safe(candidate, estimate)
        }
        guard estimate.support == .eip1559,
            let baseFee
        else {
            if estimate.support == .unknown,
                candidate.feeProvenance.containsUserControlledValue(
                    for: preparedFee
                )
            {
                return .userControlledUnsafe(candidate, estimate)
            } else {
                return .unavailable(candidate, estimate)
            }
        }

        let updatedFee: PreparedTransactionFee?
        let updatedProvenance: TransactionFeeProvenance
        switch preparedFee {
        case .legacy(let existingGasPrice):
            let source =
                candidate.feeProvenance.gasPrice
                ?? candidate.feeSource
            guard source.isWalletManaged else {
                return .userControlledUnsafe(candidate, estimate)
            }
            let priority: BigUInt
            if source == .slider {
                if let previousBaseFee =
                    transaction.feeBasisBaseFeePerGas,
                    existingGasPrice > previousBaseFee
                {
                    priority = existingGasPrice - previousBaseFee
                } else {
                    guard let recommendedPriority =
                        estimate.info?.recommendedPriorityFee else {
                        return .unavailable(candidate, estimate)
                    }
                    priority = recommendedPriority
                }
            } else {
                guard
                    let recommendedPriority =
                        estimate.info?.recommendedPriorityFee
                else {
                    return .unavailable(candidate, estimate)
                }
                priority = recommendedPriority
            }
            let gasPrice: BigUInt?
            if source == .slider {
                let sliderGasPrice = baseFee + priority
                gasPrice =
                    Transaction.isValidUInt256(sliderGasPrice)
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
            let maxFeeSource =
                candidate.feeProvenance.maxFeePerGas
                ?? candidate.feeSource
            let priority: BigUInt
            if prioritySource.isUserControlled || prioritySource == .slider {
                priority = existingPriority
            } else {
                if maxFeeSource.isUserControlled,
                    existingMaxFee <= baseFee
                {
                    return .userControlledUnsafe(candidate, estimate)
                }
                guard
                    let recommendedPriority =
                        estimate.info?.recommendedPriorityFee
                else {
                    return .unavailable(candidate, estimate)
                }
                priority = recommendedPriority
            }

            let maxFee: BigUInt
            if maxFeeSource.isUserControlled {
                maxFee = existingMaxFee
            } else {
                guard
                    let recommended =
                        PreparedTransactionFee
                        .recommendedEIP1559(
                            baseFeePerGas: baseFee,
                            maxPriorityFeePerGas: priority
                        )
                else {
                    if prioritySource.isUserControlled {
                        return .userControlledUnsafe(candidate, estimate)
                    } else {
                        return .unavailable(candidate, estimate)
                    }
                }
                maxFee = recommended.feeCapPerGas
            }
            let fee = PreparedTransactionFee.eip1559(
                maxPriorityFeePerGas: priority,
                maxFeePerGas: maxFee
            )
            updatedFee =
                fee.hasSufficientEffectivePriorityFee(
                    baseFeePerGas: baseFee
                ) ? fee : nil
            updatedProvenance = TransactionFeeProvenance(
                maxPriorityFeePerGas: prioritySource,
                maxFeePerGas: maxFeeSource
            )
        }
        guard let updatedFee,
            updatedFee.isStructurallyValid
        else {
            if candidate.feeProvenance.containsUserControlledValue {
                return .userControlledUnsafe(candidate, estimate)
            } else {
                return .unavailable(candidate, estimate)
            }
        }
        guard updatedFee.maximumNetworkFee(gasLimit: gasLimit) != nil else {
            return .unavailable(candidate, estimate)
        }
        candidate.replacePreparedFee(
            updatedFee,
            provenance: updatedProvenance
        )
        return .walletManagedUpdated(candidate, estimate)
    }


    static func shouldInspect(_ transaction: Transaction) -> Bool {
        return transaction.interpretation == nil && !transaction.to.isEmpty
    }
    
    private func getGas(network: EthereumNetwork, transaction: Transaction) async throws -> String {
        do {
            let estimated = try await rpc.estimateGas(endpoint: network.rpcEndpoint, transaction: transaction)
            try Task.checkCancellation()
            guard let parsed = EthereumQuantity.parseUInt256(estimated), !parsed.isZero else {
                throw TransactionPreparationFailure.gasEstimationFailed
            }
            var candidate = transaction
            candidate.gas = estimated
            let confirmed = try await rpc.estimateGas(endpoint: network.rpcEndpoint, transaction: candidate)
            try Task.checkCancellation()
            guard let confirmedValue = EthereumQuantity.parseUInt256(confirmed), !confirmedValue.isZero else {
                throw TransactionPreparationFailure.gasEstimationFailed
            }
            return confirmed
        } catch {
            try Task.checkCancellation()
            throw TransactionPreparationFailure.gasEstimationFailed
        }
    }

    private static func resolveTransactionFee(
        _ transaction: Transaction, network: EthereumNetwork, estimate: GasService.Estimate
    ) -> FeeResolutionOutcome {
        guard transaction.feeIntent.isStructurallyValid else { return .unavailable(.invalidTransaction) }
        var resolved = transaction
        let previousBaseFee = transaction.feeBasisBaseFeePerGas
        let baseFee = estimate.nextBaseFee ?? estimate.currentBaseFee
        estimate.applyBaseFeeContext(to: &resolved)

        guard network.chainId > 0 else {
            return .unavailable(.gasPriceUnavailable)
        }
        if let endpointChainID = estimate.endpointChainID,
            endpointChainID != BigUInt(UInt64(network.chainId))
        {
            return .unavailable(.gasPriceUnavailable)
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
            let sliderFee = resolved.preparedFee
        {
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
                    let baseFee
                {
                    let priorityFee: BigUInt
                    if let previousBaseFee,
                        gasPrice > previousBaseFee
                    {
                        priorityFee = gasPrice - previousBaseFee
                    } else {
                        guard let recommendedPriority =
                            estimate.info?.recommendedPriorityFee else {
                            return .unavailable(.gasPriceUnavailable)
                        }
                        priorityFee = recommendedPriority
                    }
                    let refreshedGasPrice = baseFee + priorityFee
                    refreshedFee =
                        Transaction.isValidUInt256(
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
                )
            else {
                return .unavailable(.invalidTransaction)
            }
            return .prepared(resolved)
        }

        switch resolved.feeIntent {
        case .automatic:
            switch estimate.support {
            case .eip1559:
                guard let baseFee else {
                    return .unavailable(.gasPriceUnavailable)
                }
                if case .some(.legacy(let gasPrice)) =
                    resolved.preparedFee,
                    resolved.feeProvenance.gasPrice?
                        .isUserControlled == true
                {
                    guard
                        PreparedTransactionFee
                            .legacy(gasPrice: gasPrice)
                            .hasSufficientEffectivePriorityFee(
                                baseFeePerGas: baseFee
                            )
                    else {
                        return .unsafeUserFee(resolved)
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
                    guard
                        let existingPriority =
                            resolved.maxPriorityFeePerGasValue
                    else {
                        return .unsafeUserFee(resolved)
                    }
                    priorityFee = existingPriority
                } else {
                    if maxFeeSource.isUserControlled,
                        let existingMaxFee =
                            resolved.maxFeePerGasValue,
                        existingMaxFee <= baseFee
                    {
                        return .unsafeUserFee(resolved)
                    }
                    guard let recommendedPriority =
                        estimate.info?.recommendedPriorityFee else {
                        return .unavailable(.gasPriceUnavailable)
                    }
                    priorityFee = recommendedPriority
                }

                let fee: PreparedTransactionFee
                if maxFeeSource.isUserControlled {
                    guard
                        let existingMaxFee =
                            resolved.maxFeePerGasValue
                    else {
                        return .unsafeUserFee(resolved)
                    }
                    fee = .eip1559(
                        maxPriorityFeePerGas: priorityFee,
                        maxFeePerGas: existingMaxFee
                    )
                } else {
                    guard
                        let recommended =
                            PreparedTransactionFee.recommendedEIP1559(
                                baseFeePerGas: baseFee,
                                maxPriorityFeePerGas: priorityFee
                        ) else {
                        if prioritySource.isUserControlled {
                            return .unsafeUserFee(resolved)
                        } else {
                            return .unavailable(.gasPriceUnavailable)
                        }
                    }
                    fee = recommended
                }
                guard fee.hasSufficientEffectivePriorityFee(
                    baseFeePerGas: baseFee
                ) else {
                    if prioritySource.isUserControlled
                        || maxFeeSource.isUserControlled {
                        return .unsafeUserFee(resolved)
                    } else {
                        return .unavailable(.gasPriceUnavailable)
                    }
                }
                guard apply(
                    fee,
                    source: .automatic,
                    preservingExistingSources: true
                ) else {
                    if prioritySource.isUserControlled
                        || maxFeeSource.isUserControlled {
                        return .unsafeUserFee(resolved)
                    } else {
                        return .unavailable(.gasPriceUnavailable)
                    }
                }
            case .legacy:
                if resolved.feeProvenance.gasPrice?
                    .isUserControlled == true,
                    let existingFee = resolved.preparedFee,
                    existingFee.gasPrice != nil
                {
                    guard existingFee.isStructurallyValid,
                        existingFee.gasPrice.map({
                            Transaction.isValidGasPrice($0, on: network)
                        }) == true
                    else {
                        return .unsafeUserFee(resolved)
                    }
                    break
                }
                guard let gasPrice = estimate.gasPrice,
                    apply(
                        .legacy(gasPrice: gasPrice),
                        source: .automatic,
                        preservingExistingSources: false
                    )
                else {
                    return .unavailable(.gasPriceUnavailable)
                }
            case .unknown:
                if let existingFee = resolved.preparedFee,
                    existingFee.isStructurallyValid,
                    resolved.feeProvenance.containsUserControlledValue(
                        for: existingFee
                    ),
                    existingFee.gasPrice.map({
                        Transaction.isValidGasPrice($0, on: network)
                    }) != false
                {
                    break
                }
                return .unavailable(.gasPriceUnavailable)
            }

        case .legacy(let requestedGasPrice):
            let gasPriceSource =
                resolved.feeProvenance.gasPrice
                ?? (requestedGasPrice == nil ? .automatic : .dapp)
            var candidateGasPrice: BigUInt?
            if gasPriceSource.isUserControlled {
                candidateGasPrice =
                    resolved.preparedFee?.gasPrice ?? requestedGasPrice
            } else if estimate.support == .eip1559,
                let baseFee
            {
                guard
                    let priorityFee =
                        estimate.info?.recommendedPriorityFee
                else {
                    return .unavailable(.gasPriceUnavailable)
                }
                guard
                    let derivedGasPrice =
                        GasService
                        .suggestedLegacyGasPrice(
                            baseFeePerGas: baseFee,
                            priorityFeePerGas: priorityFee
                        )
                else {
                    return .unavailable(.invalidTransaction)
                }
                candidateGasPrice = derivedGasPrice
            } else {
                candidateGasPrice = estimate.gasPrice
            }
            guard var gasPrice = candidateGasPrice else {
                return .unavailable(.gasPriceUnavailable)
            }

            if estimate.support == .eip1559 {
                guard let baseFee else {
                    return .unavailable(.gasPriceUnavailable)
                }
                if gasPriceSource.isWalletManaged {
                    let minimum =
                        baseFee
                        + PreparedTransactionFee.minimumPriorityFeePerGas
                    guard Transaction.isValidUInt256(minimum) else {
                        return .unavailable(.invalidTransaction)
                    }
                    if gasPrice < minimum {
                        gasPrice = minimum
                    }
                } else if gasPrice < baseFee {
                    return .unsafeUserFee(resolved)
                }
            }
            guard Transaction.isValidGasPrice(gasPrice, on: network) else {
                if gasPriceSource.isUserControlled {
                    return .unsafeUserFee(resolved)
                } else {
                    return .unavailable(.gasPriceUnavailable)
                }
            }
            guard
                apply(
                    .legacy(gasPrice: gasPrice),
                    source: gasPriceSource,
                    preservingExistingSources: true
                )
            else {
                if gasPriceSource.isUserControlled {
                    return .unsafeUserFee(resolved)
                } else {
                    return .unavailable(.invalidTransaction)
                }
            }

        case .eip1559(
            let requestedPriorityFee,
            let requestedMaxFee
        ):
            let prioritySource =
                resolved.feeProvenance.maxPriorityFeePerGas
                ?? (requestedPriorityFee == nil ? .automatic : .dapp)
            let maxFeeSource =
                resolved.feeProvenance.maxFeePerGas
                ?? (requestedMaxFee == nil ? .automatic : .dapp)
            guard estimate.support == .eip1559,
                let baseFee
            else {
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
                    )
                else {
                    return .unavailable(.gasPriceUnavailable)
                }
                break
            }
            let priorityFee: BigUInt
            if prioritySource.isUserControlled
                || prioritySource == .slider
            {
                guard
                    let controlledPriority =
                        resolved.preparedFee?.maxPriorityFeePerGas
                        ?? requestedPriorityFee
                else {
                    return .unsafeUserFee(resolved)
                }
                priorityFee = controlledPriority
            } else {
                if maxFeeSource.isUserControlled,
                    let controlledMaxFee =
                        resolved.preparedFee?.maxFeePerGas
                        ?? requestedMaxFee,
                    controlledMaxFee <= baseFee
                {
                    return .unsafeUserFee(resolved)
                }
                guard
                    let recommendedPriority =
                        estimate.info?.recommendedPriorityFee
                else {
                    return .unavailable(.gasPriceUnavailable)
                }
                priorityFee = recommendedPriority
            }

            let maxFee: BigUInt
            if maxFeeSource.isUserControlled {
                guard
                    let controlledMaxFee =
                        resolved.preparedFee?.maxFeePerGas
                        ?? requestedMaxFee
                else {
                    return .unsafeUserFee(resolved)
                }
                maxFee = controlledMaxFee
            } else {
                guard
                    let recommended =
                        PreparedTransactionFee
                        .recommendedEIP1559(
                            baseFeePerGas: baseFee,
                            maxPriorityFeePerGas: priorityFee
                        )
                else {
                    if prioritySource.isUserControlled {
                        return .unsafeUserFee(resolved)
                    } else {
                        return .unavailable(.invalidTransaction)
                    }
                }
                maxFee = recommended.feeCapPerGas
            }
            let fee = PreparedTransactionFee.eip1559(
                maxPriorityFeePerGas: priorityFee,
                maxFeePerGas: maxFee
            )
            guard
                fee.hasSufficientEffectivePriorityFee(
                    baseFeePerGas: baseFee
                )
            else {
                if prioritySource.isUserControlled
                    || maxFeeSource.isUserControlled
                {
                    return .unsafeUserFee(resolved)
                } else {
                    return .unavailable(.invalidTransaction)
                }
            }
            guard
                apply(
                    fee,
                    source: .automatic,
                    preservingExistingSources: true
                )
            else {
                if prioritySource.isUserControlled
                    || maxFeeSource.isUserControlled
                {
                    return .unsafeUserFee(resolved)
                } else {
                    return .unavailable(.invalidTransaction)
                }
            }
        }

        if estimate.support == .unknown,
            let basis = resolved.feeBasisBaseFeePerGas,
            let resolvedFee = resolved.preparedFee,
            !resolvedFee.hasSufficientEffectivePriorityFee(
                baseFeePerGas: basis
            )
        {
            if resolved.feeProvenance.containsUserControlledValue(
                for: resolvedFee
            ) {
                return .unsafeUserFee(resolved)
            } else {
                return .unavailable(.gasPriceUnavailable)
            }
        }

        return .prepared(resolved)
    }

    private func getNonce(network: EthereumNetwork, from: String) async throws -> String {
        do {
            let nonce = try await rpc.fetchNonce(endpoint: network.rpcEndpoint, for: from)
            try Task.checkCancellation()
            guard EthereumQuantity.parseUInt256(nonce) != nil else {
                throw TransactionPreparationFailure.nonceUnavailable
            }
            return nonce
        } catch {
            try Task.checkCancellation()
            throw TransactionPreparationFailure.nonceUnavailable
        }
    }
}
